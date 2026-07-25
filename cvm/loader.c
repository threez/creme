/* Reads a .cvmc file (written by src/scheme/compile/cvm_serializer.cr) into
 * the runtime Chunk tree, then rewrites every global-name operand (originally
 * a const-pool index into a SchemeSym) into a direct index into the VM's own
 * global table — see cvm/README.md's "global resolution" section for why
 * this is sound here (a single static program, no eval/redefinition) even
 * though it'd be unsound in general. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <gc.h>

#include "opcodes.h"
#include "vm.h"

typedef struct {
  FILE *f;
  const char *path;
} Reader;

static void must_read(Reader *r, void *buf, size_t n) {
  if (fread(buf, 1, n, r->f) != n) {
    cvm_abort("cvm: truncated or corrupt bytecode file %s", r->path);
  }
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

/* General recursive datum reader (mirrors cvm_serializer.cr's write_datum) —
 * used both for an ordinary chunk const (any of CTAG_INT/FLOAT/SYM/STR/
 * BOOL/NIL/PAIR/VECTOR — a real `(quote (a b c))`-style literal can be
 * arbitrarily nested pairs/vectors, not just the flat scalar tags the
 * original bench/creme.scm-only scope ever needed) and for a QQ_CONST
 * template node's own literal-fragment payload (e.g. the `(b c)` in
 * `` `(a (b c) ,d) ``). Pairs/vectors built here are GC_MALLOC'd like every
 * other heap value, even though `vm` itself isn't available yet at this
 * point in loading (GC_MALLOC needs no VM — it's Boehm's own global heap,
 * not the per-VM arena this used to be). */
static Value read_datum(Reader *r) {
  unsigned char tag = read_u8(r);
  switch (tag) {
  case CTAG_INT:
    return v_int(read_i64(r));
  case CTAG_FLOAT:
    return v_float(read_f64(r));
  case CTAG_SYM: {
    int len = read_i32(r);
    char *s = read_bytes(r, len);
    return v_sym(s, len);
  }
  case CTAG_STR: {
    int len = read_i32(r);
    char *s = read_bytes(r, len);
    return v_str(s, len);
  }
  case CTAG_BOOL:
    return v_bool(read_u8(r));
  case CTAG_NIL:
    return v_nil();
  case CTAG_CHAR:
    return v_char(read_i64(r));
  case CTAG_PAIR: {
    Pair *p = GC_MALLOC(sizeof(Pair));
    p->car = read_datum(r);
    p->cdr = read_datum(r);
    return v_pair(p);
  }
  case CTAG_VECTOR: {
    int n = read_i32(r);
    Vector *vec = GC_MALLOC(sizeof(Vector));
    vec->len = n;
    vec->items = GC_MALLOC(sizeof(Value) * (size_t)(n ? n : 1));
    for (int i = 0; i < n; i++) vec->items[i] = read_datum(r);
    return v_vector(vec);
  }
  default:
    cvm_abort("cvm: unknown const/datum tag %d in %s", tag, r->path);
  }
}

static QQTemplate *read_qq_template(Reader *r) {
  QQTemplate *t = GC_MALLOC(sizeof(QQTemplate));
  t->tag = read_u8(r);
  switch (t->tag) {
  case QQ_CONST:
    t->const_value = read_datum(r);
    break;
  case QQ_HOLE:
  case QQ_SPLICE:
    break;
  case QQ_LIST:
    t->n_items = read_i32(r);
    t->items = GC_MALLOC(sizeof(QQTemplate *) * (size_t)(t->n_items ? t->n_items : 1));
    for (int i = 0; i < t->n_items; i++) t->items[i] = read_qq_template(r);
    t->tail = read_qq_template(r);
    break;
  case QQ_VECTOR:
    t->n_items = read_i32(r);
    t->items = GC_MALLOC(sizeof(QQTemplate *) * (size_t)(t->n_items ? t->n_items : 1));
    for (int i = 0; i < t->n_items; i++) t->items[i] = read_qq_template(r);
    break;
  default:
    cvm_abort("cvm: unknown QQTemplate tag %d in %s", t->tag, r->path);
  }
  return t;
}

/* Mirrors cvm_serializer.cr's write_case_dispatch_table — Op::CaseDispatch's
 * jump table (see vm.h's CaseDispatchTable/CaseDispatchEntry doc comment). */
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

static Chunk *read_chunk(Reader *r) {
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
    ins->line = read_i32(r);
    if (ins->op < 0 || ins->op >= OP_COUNT) {
      cvm_abort("cvm: unknown opcode id %d in %s (out of sync with cvm_serializer.cr?)", ins->op, r->path);
    }
  }

  c->n_consts = read_i32(r);
  c->consts = GC_MALLOC(sizeof(Value) * (size_t)c->n_consts);
  for (int i = 0; i < c->n_consts; i++) {
    c->consts[i] = read_datum(r);
  }

  c->n_protos = read_i32(r);
  c->protos = GC_MALLOC(sizeof(Chunk *) * (size_t)c->n_protos);
  for (int i = 0; i < c->n_protos; i++) {
    c->protos[i] = read_chunk(r);
  }

  c->n_upvalues = read_i32(r);
  c->upvalues = GC_MALLOC(sizeof(UpvalDesc) * (size_t)c->n_upvalues);
  for (int i = 0; i < c->n_upvalues; i++) {
    c->upvalues[i].from_parent_local = read_u8(r);
    c->upvalues[i].index = read_i32(r);
  }

  c->param_count = read_i32(r);
  c->has_rest = read_u8(r);
  c->num_registers = read_i32(r);

  int name_len = read_i32(r);
  c->name = read_bytes(r, name_len);

  c->n_qq_templates = read_i32(r);
  c->qq_templates = GC_MALLOC(sizeof(QQTemplate *) * (size_t)(c->n_qq_templates ? c->n_qq_templates : 1));
  for (int i = 0; i < c->n_qq_templates; i++) {
    c->qq_templates[i] = read_qq_template(r);
  }

  c->n_case_tables = read_i32(r);
  c->case_tables = GC_MALLOC(sizeof(CaseDispatchTable) * (size_t)(c->n_case_tables ? c->n_case_tables : 1));
  for (int i = 0; i < c->n_case_tables; i++) {
    c->case_tables[i] = read_case_dispatch_table(r);
  }

  return c;
}

/* Second pass: resolve every GetGlobal/DefGlobal/CallGlobal/TailCallGlobal
 * operand from "const-pool index of a symbol" to "index into vm->globals",
 * recursively through every proto. Must run after the WHOLE tree is loaded
 * (not interleaved with read_chunk) only in the sense that it needs each
 * chunk's own consts already populated — which they are by the time
 * read_chunk returns, so a single recursive walk right after loading works
 * fine. */
static void resolve_globals(VM *vm, Chunk *c) {
  for (int i = 0; i < c->n_instrs; i++) {
    Instruction *ins = &c->instrs[i];
    switch (ins->op) {
    case OP_GETGLOBAL: {
      Value name = c->consts[ins->b];
      ins->b = cvm_global_intern(vm, name.as.str.chars, name.as.str.len);
      break;
    }
    case OP_DEFGLOBAL: {
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
    default:
      break;
    }
  }
  for (int i = 0; i < c->n_protos; i++) {
    resolve_globals(vm, c->protos[i]);
  }
}

Chunk **cvm_load(const char *path, int *n_top_level_chunks, VM *vm) {
  Reader r = {fopen(path, "rb"), path};
  if (!r.f) cvm_abort("cvm: cannot open %s", path);

  char magic[4];
  must_read(&r, magic, 4);
  if (memcmp(magic, "CVM2", 4) != 0) {
    cvm_abort("cvm: %s is not a CVM2 bytecode file (re-emit with `creme --emit-cvm`?)", path);
  }

  int source_file_len = read_i32(&r);
  vm->source_file = read_bytes(&r, source_file_len);

  int n = read_i32(&r);
  Chunk **chunks = GC_MALLOC(sizeof(Chunk *) * (size_t)n);
  for (int i = 0; i < n; i++) {
    chunks[i] = read_chunk(&r);
  }
  fclose(r.f);

  for (int i = 0; i < n; i++) {
    resolve_globals(vm, chunks[i]);
  }

  *n_top_level_chunks = n;
  return chunks;
}
