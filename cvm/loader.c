/* Reads a "SCB1" file (the same format src/scheme/compile/chunk_serializer.cr/
 * chunk_deserializer.cr round-trip on the Crystal side, written here by
 * src/scheme/compile/cvm_emitter.cr) into the runtime Chunk tree, then
 * rewrites every global-name operand (originally a const-pool index into a
 * SchemeSym) into a direct index into the VM's own global table — see
 * cvm/README.md's "global resolution" section for why this is sound here (a
 * single static program, no eval/redefinition) even though it'd be unsound
 * in general.
 *
 * SCB1 encodes exactly ONE chunk, no multi-chunk envelope — see
 * cvm_emitter.cr's own header comment for why: a whole script (plus its
 * transitively-imported pure-Scheme library bodies) is compiled into one
 * combined Chunk on the Crystal side specifically so this loader doesn't
 * need to invent one. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <gc.h>

#include "opcodes.h"
#include "vm.h"

/* Either a real file (cvm_load, the normal `cvm foo.cvmc` path) or an
 * in-memory byte buffer (cvm_load_from_bytes, used by the `load-chunk-
 * bytes` builtin to load a bytevector a running program just computed --
 * e.g. the self-hosted compiler's own compile-source-to-bytes output).
 * `read_chunk`/`read_datum`/etc. below never care which mode is active --
 * only the primitives here (must_read/read_u8/...) branch on it. */
typedef struct {
  FILE *f;                   /* NULL when reading from a buffer instead */
  const unsigned char *buf;  /* NULL when reading from a file instead */
  size_t buf_len, buf_pos;
  const char *path; /* diagnostic label only -- a fixed string like
                      * "<bytevector>" when reading from a buffer, since
                      * there's no filename in that case. */
} Reader;

static void must_read(Reader *r, void *dst, size_t n) {
  if (r->f) {
    if (fread(dst, 1, n, r->f) != n) {
      cvm_abort("cvm: truncated or corrupt bytecode file %s", r->path);
    }
    return;
  }
  if (r->buf_pos + n > r->buf_len) {
    cvm_abort("cvm: truncated or corrupt bytecode in %s", r->path);
  }
  memcpy(dst, r->buf + r->buf_pos, n);
  r->buf_pos += n;
}

static int32_t read_i32(Reader *r) {
  int32_t v;
  must_read(r, &v, sizeof(v));
  return v;
}

static int64_t read_i64(Reader *r) {
  int64_t v;
  must_read(r, &v, sizeof(v));
  return v;
}

static double read_f64(Reader *r) {
  double v;
  must_read(r, &v, sizeof(v));
  return v;
}

static unsigned char read_u8(Reader *r) {
  unsigned char v;
  must_read(r, &v, 1);
  return v;
}

/* Owning copy — the file buffer isn't kept around, so string/symbol consts
 * need their own storage (leaked, like everything else here — see
 * value.h's header comment). */
static char *read_bytes(Reader *r, int len) {
  char *buf = GC_MALLOC((size_t)len + 1);
  if (len > 0) must_read(r, buf, (size_t)len);
  buf[len] = '\0';
  return buf;
}

/* Looks up `name` among already-registered globals (builtins are registered
 * by main.c BEFORE cvm_load runs — see main.c) without creating a new
 * unbound slot for a miss, unlike cvm_global_intern. Mirrors
 * chunk_deserializer.cr's TAG_BUILTIN handling (`env.get?(name)`, nilable).
 * A miss returns v_nil() — same "unused placeholder" convention the old
 * CVM2 loader used for every Builtin const, since cvm's fused-op deopt
 * paths (the only consumer of this kind of const) hard-abort rather than
 * actually falling back to it (see cvm/README.md). */
static Value resolve_builtin_const(VM *vm, const char *name, int len) {
  for (int i = 0; i < vm->n_globals; i++) {
    if ((int)strlen(vm->globals[i].name) == len && memcmp(vm->globals[i].name, name, (size_t)len) == 0 && vm->globals[i].bound) {
      return vm->globals[i].value;
    }
  }
  return v_nil();
}

/* General recursive datum reader (mirrors ChunkSerializer's write_datum) —
 * used both for an ordinary chunk const and for a QQ_CONST template node's
 * own literal-fragment payload (e.g. the `(b c)` in `` `(a (b c) ,d) ``).
 * TAG_RATIONAL/TAG_COMPLEX build real T_RATIONAL/T_COMPLEX Values (see
 * value.h) via the same make_rational_from_mpq/make_complex construction
 * path vm.c's own arithmetic uses — modules/creme/bytecode.sld's
 * write-datum! always emits a rational's numerator/denominator already
 * reduced to lowest terms as plain i64s (SchemeRational/T_RATIONAL's own
 * invariant), so this never needs GMP's bignum path itself, just wrapping
 * them back into an mpq_t. TAG_BLOB builds a real Bytevector (see
 * value.h). Pairs/vectors/bytevectors built here are GC_MALLOC'd like
 * every other heap value, even though `vm` itself isn't needed for those
 * cases (only TAG_BUILTIN's by-name lookup needs it). */
static Value read_datum(Reader *r, VM *vm) {
  unsigned char tag = read_u8(r);
  switch (tag) {
  case TAG_INT:
    return v_int(read_i64(r));
  case TAG_FLOAT:
    return v_float(read_f64(r));
  case TAG_RATIONAL: {
    int64_t num = read_i64(r);
    int64_t den = read_i64(r);
    mpq_t q;
    mpq_init(q);
    mpq_set_si(q, (long)num, (unsigned long)den);
    Value result = make_rational_from_mpq(q);
    mpq_clear(q);
    return result;
  }
  case TAG_COMPLEX: {
    Value real = read_datum(r, vm);
    Value imag = read_datum(r, vm);
    return make_complex(real, imag);
  }
  case TAG_SYM: {
    int len = read_i32(r);
    char *s = read_bytes(r, len);
    return v_sym(s, len);
  }
  case TAG_STR: {
    int len = read_i32(r);
    char *s = read_bytes(r, len);
    return v_str(s, len);
  }
  case TAG_BOOL:
    return v_bool(read_u8(r));
  case TAG_NIL:
    return v_nil();
  case TAG_CHAR:
    return v_char(read_i64(r));
  case TAG_PAIR: {
    Pair *p = GC_MALLOC(sizeof(Pair));
    p->car = read_datum(r, vm);
    p->cdr = read_datum(r, vm);
    return v_pair(p);
  }
  case TAG_VECTOR: {
    int n = read_i32(r);
    Vector *vec = GC_MALLOC(sizeof(Vector));
    vec->len = n;
    vec->items = GC_MALLOC(sizeof(Value) * (size_t)(n ? n : 1));
    for (int i = 0; i < n; i++) vec->items[i] = read_datum(r, vm);
    return v_vector(vec);
  }
  case TAG_BLOB: {
    int n = read_i32(r);
    Bytevector *bv = GC_MALLOC(sizeof(Bytevector));
    bv->len = n;
    bv->bytes = GC_MALLOC((size_t)(n ? n : 1));
    for (int i = 0; i < n; i++) bv->bytes[i] = read_u8(r);
    return v_bytevector(bv);
  }
  case TAG_BUILTIN: {
    int len = read_i32(r);
    char *s = read_bytes(r, len);
    return resolve_builtin_const(vm, s, len);
  }
  default:
    cvm_abort("cvm: unknown const/datum tag %d in %s", tag, r->path);
  }
}

static QQTemplate *read_qq_template(Reader *r, VM *vm) {
  QQTemplate *t = GC_MALLOC(sizeof(QQTemplate));
  t->tag = read_u8(r);
  switch (t->tag) {
  case QQ_CONST:
    t->const_value = read_datum(r, vm);
    break;
  case QQ_HOLE:
  case QQ_SPLICE:
    break;
  case QQ_LIST:
    t->n_items = read_i32(r);
    t->items = GC_MALLOC(sizeof(QQTemplate *) * (size_t)(t->n_items ? t->n_items : 1));
    for (int i = 0; i < t->n_items; i++) t->items[i] = read_qq_template(r, vm);
    t->tail = read_qq_template(r, vm);
    break;
  case QQ_VECTOR:
    t->n_items = read_i32(r);
    t->items = GC_MALLOC(sizeof(QQTemplate *) * (size_t)(t->n_items ? t->n_items : 1));
    for (int i = 0; i < t->n_items; i++) t->items[i] = read_qq_template(r, vm);
    break;
  default:
    cvm_abort("cvm: unknown QQTemplate tag %d in %s", t->tag, r->path);
  }
  return t;
}

/* Mirrors ChunkSerializer's write_case_dispatch_table — Op::CaseDispatch's
 * jump table (see vm.h's CaseDispatchTable/CaseDispatchEntry doc comment).
 * Unchanged from the old CVM2 layout. */
static CaseDispatchTable read_case_dispatch_table(Reader *r) {
  CaseDispatchTable t;
  t.default_target = read_i32(r);
  t.n_entries = read_i32(r);
  t.entries = GC_MALLOC(sizeof(CaseDispatchEntry) * (size_t)(t.n_entries ? t.n_entries : 1));
  for (int i = 0; i < t.n_entries; i++) {
    CaseDispatchEntry *e = &t.entries[i];
    e->tag = read_u8(r);
    e->sval = NULL;
    e->sval_len = 0;
    switch (e->tag) {
    case CDK_INT:
    case CDK_CHAR:
    case CDK_BOOL:
      e->ival = read_i64(r);
      break;
    case CDK_SYM:
      e->sval_len = read_i32(r);
      e->sval = read_bytes(r, e->sval_len);
      break;
    case CDK_NIL:
      break;
    default:
      cvm_abort("cvm: unknown CaseDispatchKey tag %d in %s", e->tag, r->path);
    }
    e->target = read_i32(r);
  }
  return t;
}

static Chunk *read_chunk(Reader *r, VM *vm) {
  Chunk *c = GC_MALLOC(sizeof(Chunk));

  c->n_instrs = read_i32(r);
  c->instrs = GC_MALLOC(sizeof(Instruction) * (size_t)c->n_instrs);
  for (int i = 0; i < c->n_instrs; i++) {
    Instruction *ins = &c->instrs[i];
    ins->op = read_i32(r);
    ins->a = read_i32(r);
    ins->b = read_i32(r);
    ins->c = read_i32(r);
    ins->d = read_i32(r);
    ins->has_pos = read_u8(r);
    if (ins->has_pos) {
      int file_len = read_i32(r);
      ins->file = read_bytes(r, file_len);
      ins->line = read_i32(r);
      ins->col = read_i32(r);
    } else {
      ins->file = NULL;
      ins->line = 0;
      ins->col = 0;
    }
    if (ins->op < 0 || ins->op >= OP_COUNT) {
      cvm_abort("cvm: unknown opcode id %d in %s", ins->op, r->path);
    }
  }

  c->n_consts = read_i32(r);
  c->consts = GC_MALLOC(sizeof(Value) * (size_t)c->n_consts);
  for (int i = 0; i < c->n_consts; i++) {
    c->consts[i] = read_datum(r, vm);
  }

  c->n_protos = read_i32(r);
  c->protos = GC_MALLOC(sizeof(Chunk *) * (size_t)c->n_protos);
  for (int i = 0; i < c->n_protos; i++) {
    c->protos[i] = read_chunk(r, vm);
  }

  c->n_upvalues = read_i32(r);
  c->upvalues = GC_MALLOC(sizeof(UpvalDesc) * (size_t)c->n_upvalues);
  for (int i = 0; i < c->n_upvalues; i++) {
    c->upvalues[i].from_parent_local = read_u8(r);
    c->upvalues[i].index = read_i32(r);
    int name_len = read_i32(r);
    c->upvalues[i].name = read_bytes(r, name_len);
  }

  c->param_count = read_i32(r);
  c->has_rest = read_u8(r);
  c->num_registers = read_i32(r);

  int name_len = read_i32(r);
  c->name = read_bytes(r, name_len);

  c->n_qq_templates = read_i32(r);
  c->qq_templates = GC_MALLOC(sizeof(QQTemplate *) * (size_t)(c->n_qq_templates ? c->n_qq_templates : 1));
  for (int i = 0; i < c->n_qq_templates; i++) {
    c->qq_templates[i] = read_qq_template(r, vm);
  }

  c->n_case_tables = read_i32(r);
  c->case_tables = GC_MALLOC(sizeof(CaseDispatchTable) * (size_t)(c->n_case_tables ? c->n_case_tables : 1));
  for (int i = 0; i < c->n_case_tables; i++) {
    c->case_tables[i] = read_case_dispatch_table(r);
  }

  return c;
}

/* Second pass: resolve every GetGlobal/DefGlobal/SetGlobal/CallGlobal/
 * TailCallGlobal operand from "const-pool index of a symbol" to "index into
 * vm->globals", recursively through every proto. Must run after the WHOLE
 * tree is loaded (not interleaved with read_chunk) only in the sense that it
 * needs each chunk's own consts already populated — which they are by the
 * time read_chunk returns, so a single recursive walk right after loading
 * works fine. SetGlobal's operand is patched here even though its own
 * dispatch handler isn't implemented yet (see vm.c's L_UNIMPL) — this pass
 * doesn't care whether an op is implemented, only what shape its operand is. */
static void resolve_globals(VM *vm, Chunk *c) {
  for (int i = 0; i < c->n_instrs; i++) {
    Instruction *ins = &c->instrs[i];
    switch (ins->op) {
    case OP_GETGLOBAL: {
      Value name = c->consts[ins->b];
      ins->b = cvm_global_intern(vm, name.as.str.chars, name.as.str.len);
      break;
    }
    case OP_DEFGLOBAL:
    case OP_SETGLOBAL: {
      Value name = c->consts[ins->a];
      ins->a = cvm_global_intern(vm, name.as.str.chars, name.as.str.len);
      break;
    }
    case OP_CALLGLOBAL:
    case OP_TAILCALLGLOBAL: {
      Value name = c->consts[ins->d];
      ins->d = cvm_global_intern(vm, name.as.str.chars, name.as.str.len);
      break;
    }
    case OP_RETURNGLOBAL: {
      Value name = c->consts[ins->a];
      ins->a = cvm_global_intern(vm, name.as.str.chars, name.as.str.len);
      break;
    }
    default:
      break;
    }
  }
  for (int i = 0; i < c->n_protos; i++) {
    resolve_globals(vm, c->protos[i]);
  }
}

Chunk *cvm_load(const char *path, VM *vm) {
  Reader r = {0};
  r.path = path;
  r.f = fopen(path, "rb");
  if (!r.f) cvm_abort("cvm: cannot open %s", path);

  char magic[4];
  must_read(&r, magic, 4);
  if (memcmp(magic, "SCB1", 4) != 0) {
    cvm_abort("cvm: %s is not an SCB1 bytecode file (re-emit with `creme --emit-cvm`?)", path);
  }

  Chunk *chunk = read_chunk(&r, vm);
  fclose(r.f);

  resolve_globals(vm, chunk);
  return chunk;
}

/* In-memory counterpart of cvm_load -- see the Reader struct's own doc
 * comment above. Used by (creme bootstrap)'s cvm-side `load-chunk-bytes`
 * builtin (bootstrap.c) to load a bytevector a running program just
 * computed (e.g. the self-hosted compiler's own compile-source-to-bytes
 * output) without ever touching the filesystem. */
Chunk *cvm_load_from_bytes(VM *vm, const unsigned char *bytes, size_t len) {
  Reader r = {0};
  r.path = "<bytevector>";
  r.buf = bytes;
  r.buf_len = len;

  char magic[4];
  must_read(&r, magic, 4);
  if (memcmp(magic, "SCB1", 4) != 0) {
    cvm_abort("cvm: load-chunk-bytes: not an SCB1 bytecode blob");
  }

  Chunk *chunk = read_chunk(&r, vm);
  resolve_globals(vm, chunk);
  return chunk;
}
