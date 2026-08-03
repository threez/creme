/* Reads an "ICE1" file (the same format src/creme/compile/chunk_serializer.cr/
 * chunk_deserializer.cr round-trip on the Crystal side, written here by
 * src/creme/compile/icecreme_emitter.cr) into the runtime Chunk tree, then
 * rewrites every global-name operand (originally a const-pool index into a
 * SchemeSym) into a direct index into the VM's own global table — see
 * icecreme/README.md's "global resolution" section for why this is sound here (a
 * single static program, no eval/redefinition) even though it'd be unsound
 * in general.
 *
 * ICE1 encodes exactly ONE chunk, no multi-chunk envelope — see
 * icecreme_emitter.cr's own header comment for why: a whole script (plus its
 * transitively-imported pure-Scheme library bodies) is compiled into one
 * combined Chunk on the Crystal side specifically so this loader doesn't
 * need to invent one. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <gc.h>

#include "opcodes.h"
#include "vm.h"

/* Either a real file (creme_load, the normal `icecreme foo.ice` path) or an
 * in-memory byte buffer (creme_load_from_bytes, used by the `load-chunk-
 * bytes` builtin to load a bytevector a running program just computed --
 * e.g. the self-hosted compiler's own compile-source-to-bytes output).
 * `read_chunk`/`read_datum`/etc. below never care which mode is active --
 * only the primitives here (must_read/read_u8/...) branch on it. */
/* R7RS datum labels (#n=/#n#) -- one entry per TAG_LABEL_DEF seen so far
 * in the CURRENT top-level datum (see read_datum's own doc comment for
 * why the table resets there, not per-Reader-lifetime). `value` is
 * filled in immediately for TAG_LABEL_DEF on a pair/vector (the
 * container's own pointer already exists before its contents are read --
 * see read_datum_rec's TAG_PAIR/TAG_VECTOR cases), so a TAG_LABEL_REF
 * appearing anywhere inside that SAME container's own contents (a
 * genuine cycle) already resolves correctly; for any other tag, `value`
 * is filled in only after the datum is fully read (no cycle is possible
 * through a non-container value anyway). */
#define CREME_DATUM_LABELS_CAP 256
typedef struct {
  int id;
  Value value;
} DatumLabel;

typedef struct {
  FILE *f;                   /* NULL when reading from a buffer instead */
  const unsigned char *buf;  /* NULL when reading from a file instead */
  size_t buf_len, buf_pos;
  const char *path; /* diagnostic label only -- a fixed string like
                      * "<bytevector>" when reading from a buffer, since
                      * there's no filename in that case. */
  DatumLabel labels[CREME_DATUM_LABELS_CAP];
  int n_labels;
  int datum_depth;  /* current read_datum_rec nesting -- see its own guard */
  int chunk_depth;  /* current read_chunk nesting (nested protos) -- ditto */
  int qq_depth;     /* current read_qq_template nesting -- see its own guard */
} Reader;

static void must_read(Reader *r, void *dst, size_t n) {
  if (r->f) {
    if (fread(dst, 1, n, r->f) != n) {
      creme_abort("icecreme: truncated or corrupt bytecode file %s", r->path);
    }
    return;
  }
  if (r->buf_pos + n > r->buf_len) {
    creme_abort("icecreme: truncated or corrupt bytecode in %s", r->path);
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

/* Mirrors chunk_serializer.cr's own FORMAT_VERSION exactly (same numeric
 * value) -- bump both in lockstep, plus modules/creme/bytecode.sld's own
 * writer and chunk_deserializer.cr's own reader, whenever the on-disk
 * chunk layout changes in a way an older reader couldn't safely parse.
 * See CHANGELOG.md/icecreme/STABILITY.md for the compatibility policy this
 * exists to support. */
#define CREME_ICE1_FORMAT_VERSION 1

/* Checks the "ICE1" magic + format-version byte every entry point below
 * reads first, before anything else -- shared so the three call sites
 * (creme_peek_required_families/creme_load/creme_load_from_bytes) give
 * identical, consistent errors for either failure instead of three
 * hand-duplicated checks drifting apart over time. */
static void check_magic_and_version(Reader *r) {
  char magic[4];
  must_read(r, magic, 4);
  if (memcmp(magic, "ICE1", 4) != 0) {
    creme_abort("icecreme: %s is not an ICE1 bytecode file (re-emit with `creme --emit-icecreme`?)", r->path);
  }
  unsigned char version = read_u8(r);
  if (version != CREME_ICE1_FORMAT_VERSION) {
    creme_abort("icecreme: %s was compiled with ICE1 format version %d, this icecreme only reads version %d -- re-emit it with a matching `creme --emit-icecreme`", r->path, version, CREME_ICE1_FORMAT_VERSION);
  }
}

/* Every length/count field in the ICE1 format (instruction/const/proto/
 * upvalue/qq-template/case-table counts, and every string/vector/blob
 * length) feeds directly into a GC_MALLOC size and/or a loop bound right
 * after being read. Read plain via read_i32, a negative value wraps to a
 * huge size_t once cast for the allocation (`(size_t)-1 + 1` etc.) --
 * that's an uncontrolled, uncatchable allocation-failure abort rather
 * than the clean "corrupt bytecode" error every OTHER malformed-input
 * case here already gives. A merely-huge (but non-negative) claimed
 * count is the same hazard from the other direction: this loader is the
 * boundary an embedder crosses with untrusted/unvalidated bytecode (a
 * compiled-elsewhere .ice, or a load-chunk-bytes blob), so it must
 * reject an implausible count outright instead of attempting whatever
 * allocation it implies. CREME_LOADER_MAX_COUNT is generous headroom over
 * any real compiled program's own counts (icecreme/compiler-run.ice, the
 * largest real chunk in this repo, needs a tiny fraction of it) while
 * still well short of "attempt a multi-gigabyte allocation on a corrupt/
 * hostile 4-byte claim" -- an EARLIER, far larger value here (1 << 26)
 * still let a single crafted count force a ~512MB allocation (a pointer-
 * array field: 67,108,864 * sizeof(void*)), confirmed via `make fuzz`
 * (see fuzz/fuzz_loader.c) finding it as an out-of-memory artifact within
 * the first few hundred runs. */
#define CREME_LOADER_MAX_COUNT (1 << 21) /* 2,097,152 */

static int32_t read_count(Reader *r, const char *what) {
  int32_t v = read_i32(r);
  if (v < 0 || v > CREME_LOADER_MAX_COUNT) {
    creme_abort("icecreme: corrupt bytecode in %s: implausible %s count %d", r->path, what, v);
  }
  return v;
}

/* Owning copy — the file buffer isn't kept around, so string/symbol consts
 * need their own storage (leaked, like everything else here — see
 * value.h's header comment). */
static char *read_bytes(Reader *r, int len) {
  if (len < 0 || len > CREME_LOADER_MAX_COUNT) {
    creme_abort("icecreme: corrupt bytecode in %s: implausible byte length %d", r->path, len);
  }
  char *buf = GC_MALLOC((size_t)len + 1);
  if (len > 0) must_read(r, buf, (size_t)len);
  buf[len] = '\0';
  return buf;
}

/* Looks up `name` among already-registered globals (builtins are registered
 * by main.c BEFORE creme_load runs — see main.c) without creating a new
 * unbound slot for a miss, unlike creme_global_intern. Mirrors
 * chunk_deserializer.cr's TAG_BUILTIN handling (`env.get?(name)`, nilable).
 * A miss returns v_nil() — same "unused placeholder" convention the old
 * CVM2 loader used for every Builtin const, since icecreme's fused-op deopt
 * paths (the only consumer of this kind of const) hard-abort rather than
 * actually falling back to it (see icecreme/README.md). */
static Value resolve_builtin_const(VM *vm, const char *name, int len) {
  for (int i = 0; i < vm->n_globals; i++) {
    if ((int)strlen(vm->globals[i].name) == len && memcmp(vm->globals[i].name, name, (size_t)len) == 0 && vm->globals[i].bound) {
      return vm->globals[i].value;
    }
  }
  return v_nil();
}

static void datum_label_add(Reader *r, int id, Value v) {
  if (r->n_labels >= CREME_DATUM_LABELS_CAP) {
    creme_abort("icecreme: too many datum labels in one top-level datum (max %d) in %s", CREME_DATUM_LABELS_CAP, r->path);
  }
  r->labels[r->n_labels].id = id;
  r->labels[r->n_labels].value = v;
  r->n_labels++;
}

static int datum_label_find(Reader *r, int id, Value *out) {
  for (int i = 0; i < r->n_labels; i++) {
    if (r->labels[i].id == id) {
      *out = r->labels[i].value;
      return 1;
    }
  }
  return 0;
}

static Value read_datum_rec(Reader *r, VM *vm);

/* Max recursive-descent depth through read_datum_rec (nested pairs/
 * vectors) -- generous headroom over any realistic literal data a
 * program would embed (config tables, quoted lists), while still finite:
 * this loader's own input is untrusted bytecode (a compiled-elsewhere
 * .ice or a load-chunk-bytes blob), and an unbounded recursive descent
 * driven directly by attacker-controlled nesting is a C-stack-overflow
 * DoS (or worse, on a platform without stack-overflow protection) rather
 * than the clean "corrupt bytecode" rejection every other malformed-
 * input case here already gives. */
/* A few thousand levels is generous for any real literal while still fitting
 * comfortably in a default 8 MB thread stack -- the old 100000 needed ~20 MB
 * through the read_datum_rec -> _impl -> read_datum_rec chain and so could
 * overflow the C stack *before* this cap ever fired, defeating its purpose. */
#define CREME_LOADER_MAX_DATUM_DEPTH 4000

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
 * cases (only TAG_BUILTIN's by-name lookup needs it).
 *
 * TAG_LABEL_DEF/TAG_LABEL_REF (datum labels) are peeled off as an
 * optional PREFIX before the dispatch below, mirroring exactly how
 * ChunkSerializer's write_datum_rec emits them: TAG_LABEL_REF stands
 * alone (the whole datum IS just "go look up this earlier label",
 * already-fully-built by the time any ref can be read, since a ref can
 * only ever follow its own def in the byte stream) and returns
 * immediately; TAG_LABEL_DEF precedes an ordinary tag+bytes payload,
 * with `def_id` threaded down into the TAG_PAIR/TAG_VECTOR cases
 * specifically so THEIR OWN container pointer (already allocated before
 * its car/cdr/items are read, same as always) gets registered under
 * that label BEFORE recursing into contents — the placeholder-then-
 * patch step that makes a genuine cycle (a TAG_LABEL_REF appearing
 * inside that same container's own contents) resolve to the right,
 * already-allocated pointer instead of needing a second pass. Every
 * other tag registers its own (necessarily acyclic) value only after
 * it's fully read, same as untagged data always has. */
static Value read_datum(Reader *r, VM *vm) {
  r->n_labels = 0; /* R7RS: a datum label's scope is only the outermost datum it appears in */
  r->datum_depth = 0;
  return read_datum_rec(r, vm);
}

static Value read_datum_rec_impl(Reader *r, VM *vm);

/* Depth-checked wrapper around read_datum_rec_impl -- every recursive call
 * (TAG_COMPLEX/TAG_PAIR/TAG_VECTOR's own car/cdr/item reads) goes through
 * THIS name, not the impl directly, so the depth counter and its cap are
 * enforced at every nesting level, not just the outermost. See
 * CREME_LOADER_MAX_DATUM_DEPTH's own doc comment for why. */
static Value read_datum_rec(Reader *r, VM *vm) {
  if (r->datum_depth >= CREME_LOADER_MAX_DATUM_DEPTH) {
    creme_abort("icecreme: corrupt bytecode in %s: datum nesting too deep (max %d)", r->path, CREME_LOADER_MAX_DATUM_DEPTH);
  }
  r->datum_depth++;
  Value result = read_datum_rec_impl(r, vm);
  r->datum_depth--;
  return result;
}

static Value read_datum_rec_impl(Reader *r, VM *vm) {
  unsigned char tag = read_u8(r);
  if (tag == TAG_LABEL_REF) {
    int id = read_i32(r);
    Value v;
    if (!datum_label_find(r, id, &v)) creme_abort("icecreme: unknown datum label #%d# in %s", id, r->path);
    return v;
  }
  int def_id = -1;
  if (tag == TAG_LABEL_DEF) {
    def_id = read_i32(r);
    tag = read_u8(r); /* the labeled datum's own real tag follows */
  }
  switch (tag) {
  case TAG_INT: {
    Value result = v_int(read_i64(r));
    if (def_id >= 0) datum_label_add(r, def_id, result);
    return result;
  }
  case TAG_FLOAT: {
    Value result = v_float(read_f64(r));
    if (def_id >= 0) datum_label_add(r, def_id, result);
    return result;
  }
  case TAG_RATIONAL: {
    int64_t num = read_i64(r);
    int64_t den = read_i64(r);
    /* modules/creme/bytecode.sld's own write-datum! only ever emits an
     * already-reduced rational (T_RATIONAL's own invariant, denominator
     * never 0), but this loader can't assume the bytes it's reading
     * still honor that -- a corrupt/hostile den=0 reaches GMP's own
     * mpq_set_si/mpq_canonicalize, which detects the division by zero
     * itself and calls ITS OWN exception handler (an unconditional
     * raise/abort, not creme_abort's catchable path) -- a real,
     * reproducible crash found via `make fuzz` (see fuzz/fuzz_loader.c)
     * within a couple thousand runs. */
    if (den == 0) {
      creme_abort("icecreme: corrupt bytecode in %s: rational constant has a zero denominator", r->path);
    }
    /* mpq_set_si takes an UNSIGNED denominator; a negative den would be
     * reinterpreted as a huge magnitude, silently producing the wrong value. */
    if (den < 0) {
      creme_abort("icecreme: corrupt bytecode in %s: rational constant has a negative denominator", r->path);
    }
    mpq_t q;
    mpq_init(q);
    mpq_set_si(q, (long)num, (unsigned long)den);
    Value result = make_rational_from_mpq(q);
    mpq_clear(q);
    if (def_id >= 0) datum_label_add(r, def_id, result);
    return result;
  }
  case TAG_COMPLEX: {
    Value real = read_datum_rec(r, vm);
    Value imag = read_datum_rec(r, vm);
    Value result = make_complex(real, imag);
    if (def_id >= 0) datum_label_add(r, def_id, result);
    return result;
  }
  case TAG_SYM: {
    int len = read_i32(r);
    char *s = read_bytes(r, len);
    Value result = v_sym(s, len);
    if (def_id >= 0) datum_label_add(r, def_id, result);
    return result;
  }
  case TAG_STR: {
    int len = read_i32(r);
    char *s = read_bytes(r, len);
    Value result = v_str(s, len);
    if (def_id >= 0) datum_label_add(r, def_id, result);
    return result;
  }
  case TAG_BOOL: {
    Value result = v_bool(read_u8(r));
    if (def_id >= 0) datum_label_add(r, def_id, result);
    return result;
  }
  case TAG_NIL: {
    Value result = v_nil();
    if (def_id >= 0) datum_label_add(r, def_id, result);
    return result;
  }
  case TAG_CHAR: {
    Value result = v_char(read_i64(r));
    if (def_id >= 0) datum_label_add(r, def_id, result);
    return result;
  }
  case TAG_PAIR: {
    Pair *p = GC_MALLOC(sizeof(Pair));
    Value result = v_pair(p);
    if (def_id >= 0) datum_label_add(r, def_id, result); /* BEFORE reading contents -- see this function's own doc comment */
    p->car = read_datum_rec(r, vm);
    p->cdr = read_datum_rec(r, vm);
    return result;
  }
  case TAG_VECTOR: {
    int n = read_count(r, "vector length");
    Vector *vec = GC_MALLOC(sizeof(Vector));
    vec->len = n;
    vec->items = GC_MALLOC(sizeof(Value) * (size_t)(n ? n : 1));
    Value result = v_vector(vec);
    if (def_id >= 0) datum_label_add(r, def_id, result); /* BEFORE reading items -- see this function's own doc comment */
    for (int i = 0; i < n; i++) vec->items[i] = read_datum_rec(r, vm);
    return result;
  }
  case TAG_BLOB: {
    int n = read_count(r, "bytevector length");
    Bytevector *bv = GC_MALLOC(sizeof(Bytevector));
    bv->len = n;
    bv->bytes = GC_MALLOC((size_t)(n ? n : 1));
    for (int i = 0; i < n; i++) bv->bytes[i] = read_u8(r);
    Value result = v_bytevector(bv);
    if (def_id >= 0) datum_label_add(r, def_id, result);
    return result;
  }
  case TAG_BUILTIN: {
    int len = read_i32(r);
    char *s = read_bytes(r, len);
    Value result = resolve_builtin_const(vm, s, len);
    if (def_id >= 0) datum_label_add(r, def_id, result);
    return result;
  }
  default:
    creme_abort("icecreme: unknown const/datum tag %d in %s", tag, r->path);
  }
}

/* Same untrusted-input, C-stack-overflow rationale as CREME_LOADER_MAX_DATUM_
 * DEPTH: read_qq_template recurses per nested QQ_LIST/QQ_VECTOR item with no
 * other bound. qq_depth is balanced (inc on entry, dec before the normal
 * return) so it self-resets between top-level templates; a creme_abort mid-parse
 * fails the whole load anyway. */
#define CREME_LOADER_MAX_QQ_DEPTH 4000

static QQTemplate *read_qq_template(Reader *r, VM *vm) {
  if (r->qq_depth >= CREME_LOADER_MAX_QQ_DEPTH)
    creme_abort("icecreme: corrupt bytecode in %s: quasiquote template nesting too deep (max %d)", r->path, CREME_LOADER_MAX_QQ_DEPTH);
  r->qq_depth++;
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
    t->n_items = read_count(r, "qq-template item");
    t->items = GC_MALLOC(sizeof(QQTemplate *) * (size_t)(t->n_items ? t->n_items : 1));
    for (int i = 0; i < t->n_items; i++) t->items[i] = read_qq_template(r, vm);
    t->tail = read_qq_template(r, vm);
    break;
  case QQ_VECTOR:
    t->n_items = read_count(r, "qq-template item");
    t->items = GC_MALLOC(sizeof(QQTemplate *) * (size_t)(t->n_items ? t->n_items : 1));
    for (int i = 0; i < t->n_items; i++) t->items[i] = read_qq_template(r, vm);
    break;
  default:
    creme_abort("icecreme: unknown QQTemplate tag %d in %s", t->tag, r->path);
  }
  r->qq_depth--;
  return t;
}

/* Mirrors ChunkSerializer's write_case_dispatch_table — Op::CaseDispatch's
 * jump table (see vm.h's CaseDispatchTable/CaseDispatchEntry doc comment).
 * Unchanged from the old CVM2 layout. */
static CaseDispatchTable read_case_dispatch_table(Reader *r) {
  CaseDispatchTable t;
  t.default_target = read_i32(r);
  t.n_entries = read_count(r, "case-dispatch entry");
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
      creme_abort("icecreme: unknown CaseDispatchKey tag %d in %s", e->tag, r->path);
    }
    e->target = read_i32(r);
  }
  return t;
}

/* Max recursive-descent depth through read_chunk (nested protos, i.e.
 * lexically nested lambdas) -- generous headroom over any realistic
 * source nesting depth, for the same untrusted-input reason
 * CREME_LOADER_MAX_DATUM_DEPTH exists (see its own doc comment). */
#define CREME_LOADER_MAX_CHUNK_DEPTH 10000

static Chunk *read_chunk_impl(Reader *r, VM *vm);

/* Depth-checked wrapper -- read_chunk_impl's own recursive proto reads go
 * through THIS name, not the impl directly, enforcing the cap at every
 * nesting level. Mirrors read_datum_rec's own wrapper/impl split. */
static Chunk *read_chunk(Reader *r, VM *vm) {
  if (r->chunk_depth >= CREME_LOADER_MAX_CHUNK_DEPTH) {
    creme_abort("icecreme: corrupt bytecode in %s: chunk (proto) nesting too deep (max %d)", r->path, CREME_LOADER_MAX_CHUNK_DEPTH);
  }
  r->chunk_depth++;
  Chunk *c = read_chunk_impl(r, vm);
  r->chunk_depth--;
  return c;
}

static Chunk *read_chunk_impl(Reader *r, VM *vm) {
  Chunk *c = GC_MALLOC(sizeof(Chunk));

  c->n_instrs = read_count(r, "instruction");
  c->instrs = GC_MALLOC(sizeof(Instruction) * (size_t)c->n_instrs);
  /* Cold parallel array -- same index space as instrs, --profile-only (see
   * vm.h's InsPos doc comment). Populated here as the ICE1 stream is read
   * (position data is interleaved per-instruction on disk), then never
   * touched again except by profiler.c's report. */
  c->positions = GC_MALLOC(sizeof(InsPos) * (size_t)c->n_instrs);
  for (int i = 0; i < c->n_instrs; i++) {
    Instruction *ins = &c->instrs[i];
    InsPos *pos = &c->positions[i];
    ins->op = read_i32(r);
    ins->a = read_i32(r);
    ins->b = read_i32(r);
    ins->c = read_i32(r);
    ins->d = read_i32(r);
    pos->has_pos = read_u8(r);
    if (pos->has_pos) {
      int file_len = read_i32(r);
      pos->file = read_bytes(r, file_len);
      pos->line = read_i32(r);
      pos->col = read_i32(r);
    } else {
      pos->file = NULL;
      pos->line = 0;
      pos->col = 0;
    }
    if (ins->op < 0 || ins->op >= OP_COUNT) {
      creme_abort("icecreme: unknown opcode id %d in %s", ins->op, r->path);
    }
  }

  c->n_consts = read_count(r, "const");
  c->consts = GC_MALLOC(sizeof(Value) * (size_t)c->n_consts);
  for (int i = 0; i < c->n_consts; i++) {
    c->consts[i] = read_datum(r, vm);
  }

  c->n_protos = read_count(r, "proto");
  c->protos = GC_MALLOC(sizeof(Chunk *) * (size_t)c->n_protos);
  for (int i = 0; i < c->n_protos; i++) {
    c->protos[i] = read_chunk(r, vm);
  }

  c->n_upvalues = read_count(r, "upvalue");
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

  c->n_qq_templates = read_count(r, "qq-template");
  c->qq_templates = GC_MALLOC(sizeof(QQTemplate *) * (size_t)(c->n_qq_templates ? c->n_qq_templates : 1));
  for (int i = 0; i < c->n_qq_templates; i++) {
    c->qq_templates[i] = read_qq_template(r, vm);
  }

  c->n_case_tables = read_count(r, "case-table");
  c->case_tables = GC_MALLOC(sizeof(CaseDispatchTable) * (size_t)(c->n_case_tables ? c->n_case_tables : 1));
  for (int i = 0; i < c->n_case_tables; i++) {
    c->case_tables[i] = read_case_dispatch_table(r);
  }

  return c;
}

/* Second pass: resolve every GetGlobal/DefGlobal/SetGlobal/CallGlobal/
 * TailCallGlobal/ForLoopGuardedInc/ForLoopGuardedDec/TestGlobalIdentity operand
 * from "const-pool index of a symbol" to "index into vm->globals", recursively
 * through every proto. Must run after the WHOLE
 * tree is loaded (not interleaved with read_chunk) only in the sense that it
 * needs each chunk's own consts already populated — which they are by the
 * time read_chunk returns, so a single recursive walk right after loading
 * works fine. SetGlobal's operand is patched here even though its own
 * dispatch handler isn't implemented yet (see vm.c's L_UNIMPL) — this pass
 * doesn't care whether an op is implemented, only what shape its operand is. */
/* Every *Global, *GlobalIdentity, and ForLoopGuarded* opcode's own name operand
 * is supposed to be a const-pool INDEX of a T_SYM/T_STR const (see this
 * function's own doc comment) -- but that operand, like every other
 * Instruction field, comes straight from the untrusted bytecode file
 * with no validation of its own (ins->a/b/c/d are plain ints, read
 * in read_chunk_impl without bounds checking, since in general they're
 * register indices this loader has no fixed range to check them
 * against). A corrupt/hostile file pointing one of these specific
 * operands at an out-of-range index, or at an in-range const that
 * ISN'T actually a symbol/string (e.g. a TAG_INT const), used to reach
 * `.as.chars`/`.aux` directly -- reinterpreting an arbitrary Value's
 * bit pattern as a pointer+length and calling strlen/memcmp on it via
 * creme_global_intern. Found via `make fuzz` (see fuzz/fuzz_loader.c) as
 * a real, reproducible SIGSEGV inside strlen within the first ~1500
 * runs -- confirmed a genuine type-confusion bug, not a fuzzer/harness
 * artifact, by hand-crafting a chunk whose GetGlobal operand pointed at
 * a TAG_INT const. */
static Value global_name_const(Chunk *c, int idx, const char *path) {
  if (idx < 0 || idx >= c->n_consts) {
    creme_abort("icecreme: corrupt bytecode in %s: global-name const index %d out of range (n_consts=%d)", path, idx, c->n_consts);
  }
  Value name = c->consts[idx];
  if (name.tag != T_SYM && name.tag != T_STR) {
    creme_abort("icecreme: corrupt bytecode in %s: global-name const #%d is not a symbol/string (tag %d)", path, idx, name.tag);
  }
  return name;
}

static void check_pool_index(int idx, int count, const char *what, const char *path) {
  if (idx < 0 || idx >= count)
    creme_abort("icecreme: corrupt bytecode in %s: %s index %d out of range (count=%d)", path, what, idx, count);
}

/* Load-time bytecode validation, run once per chunk (recursively) BEFORE
 * resolve_globals rewrites any operand. Two guarantees for the untrusted
 * bytecode this loader reads (a compiled-elsewhere .ice or a load-chunk-bytes
 * blob -- see this file's header):
 *
 *   1. Every opcode is a real on-disk op id (< OP_COUNT). The dispatch table
 *      (vm.c) has a real entry for every op in [0, OP_COUNT) but is only
 *      OP_QUICK_COUNT wide, and its runtime-only quickened slots (>= OP_COUNT)
 *      must never be reachable from a serialized chunk. Rejecting op >= OP_COUNT
 *      here stops both a spoofed quickened op and an out-of-table `goto *` wild
 *      jump ("unknown opcode -> quit the program").
 *   2. Every operand that indexes a chunk pool (consts/qq_templates/case_tables/
 *      protos) is in range, closing the type-confusion / OOB-read class the
 *      global-name checks (global_name_const) already fixed for their own ops.
 *
 * SCOPE / RESIDUAL RISK (deliberately out of scope, matching the chosen minimal
 * fix): register operands (stack[base + ins->a/b/c/d]) are NOT bounds-checked
 * against num_registers, and relative jump offsets / absolute CaseDispatch
 * targets are NOT validated against n_instrs. A hostile-but-well-formed chunk
 * can still corrupt the register window or jump to a bad ip. A full per-operand
 * pass would be needed to close those. */
static void validate_chunk(Chunk *c, const char *path) {
  for (int i = 0; i < c->n_instrs; i++) {
    Instruction *ins = &c->instrs[i];
    if (ins->op < 0 || ins->op >= OP_COUNT)
      creme_abort("icecreme: corrupt bytecode in %s: unknown opcode %d at instruction %d", path, ins->op, i);
    switch (ins->op) {
    case OP_LOADK:           check_pool_index(ins->b, c->n_consts, "const-pool", path); break;
    case OP_THROW:           check_pool_index(ins->a, c->n_consts, "const-pool", path); break;
    case OP_HELPERFORM:      check_pool_index(ins->b, c->n_consts, "const-pool", path); break;
    case OP_HELPERFORMLOCAL: check_pool_index(ins->b, c->n_consts, "const-pool", path); break;
    case OP_CASEMATCH:       check_pool_index(ins->c, c->n_consts, "const-pool", path); break;
    case OP_QUASIQUOTE:      check_pool_index(ins->b, c->n_qq_templates, "qq-template", path); break;
    case OP_CASEDISPATCH:    check_pool_index(ins->b, c->n_case_tables, "case-table", path); break;
    case OP_CLOSURE:         check_pool_index(ins->b, c->n_protos, "proto", path); break;
    default: break;
    }
  }
  for (int i = 0; i < c->n_protos; i++) validate_chunk(c->protos[i], path);
}

static void resolve_globals(VM *vm, Chunk *c, const char *path) {
  for (int i = 0; i < c->n_instrs; i++) {
    Instruction *ins = &c->instrs[i];
    switch (ins->op) {
    case OP_GETGLOBAL: {
      Value name = global_name_const(c, ins->b, path);
      ins->b = creme_global_intern(vm, name.as.chars, name.aux);
      break;
    }
    case OP_DEFGLOBAL:
    case OP_SETGLOBAL: {
      Value name = global_name_const(c, ins->a, path);
      ins->a = creme_global_intern(vm, name.as.chars, name.aux);
      break;
    }
    case OP_CALLGLOBAL:
    case OP_TAILCALLGLOBAL:
    case OP_FORLOOPGUARDEDINC:
    case OP_FORLOOPGUARDEDDEC: {
      Value name = global_name_const(c, ins->d, path);
      ins->d = creme_global_intern(vm, name.as.chars, name.aux);
      break;
    }
    case OP_RETURNGLOBAL:
    case OP_TESTGLOBALIDENTITY: {
      Value name = global_name_const(c, ins->a, path);
      ins->a = creme_global_intern(vm, name.as.chars, name.aux);
      break;
    }
    default:
      break;
    }
  }
  for (int i = 0; i < c->n_protos; i++) {
    resolve_globals(vm, c->protos[i], path);
  }
}

/* Reads the "required families" metadata section (count, then that many
 * length-prefixed name strings) that sits between the magic and the chunk
 * body -- see chunk_serializer.cr's `serialize`. Always consumes exactly the
 * bytes this section occupies, regardless of whether the caller wants the
 * list, so the chunk body that follows is read from the right offset.
 * When `names_out`/`count_out` are non-NULL, fills them in with a
 * GC_MALLOC'd array of GC_MALLOC'd, NUL-terminated C strings. */
static void read_required_families(Reader *r, char ***names_out, int *count_out) {
  int count = read_count(r, "required-family");
  char **names = NULL;
  if (names_out && count > 0) {
    names = GC_MALLOC(sizeof(char *) * (size_t)count);
  }
  for (int i = 0; i < count; i++) {
    int len = read_i32(r);
    char *name = read_bytes(r, len);
    if (names) names[i] = name;
  }
  if (names_out) *names_out = names;
  if (count_out) *count_out = count;
}

/* Standalone "peek" counterpart to creme_load: opens `path`, reads just the
 * magic + required-families metadata section, then closes the file again
 * without touching the chunk body -- so main.c can learn which builtin
 * families a compiled file needs and register only those BEFORE calling the
 * real creme_load (which needs those globals already registered, since
 * resolve_globals's creme_global_intern must see them to resolve GetGlobal/
 * DefGlobal/etc. operands correctly -- see resolve_globals's own doc
 * comment above and main.c's registration-before-creme_load convention).
 * creme_load itself re-reads (and discards, if the caller passes NULL/NULL)
 * this same section when it runs for real right after -- a second, cheap
 * file open+seek, deliberately kept rather than threading one shared Reader
 * across two calls, since that would mean exposing Reader's file-handle
 * lifetime across a call boundary for no real benefit here. */
void creme_peek_required_families(const char *path, char ***names_out, int *count_out) {
  Reader r = {0};
  r.path = path;
  r.f = fopen(path, "rb");
  if (!r.f) creme_abort("icecreme: cannot open %s", path);

  check_magic_and_version(&r);

  read_required_families(&r, names_out, count_out);
  fclose(r.f);
}

Chunk *creme_load(const char *path, VM *vm, char ***required_families_out, int *required_families_count_out) {
  Reader r = {0};
  r.path = path;
  r.f = fopen(path, "rb");
  if (!r.f) creme_abort("icecreme: cannot open %s", path);

  check_magic_and_version(&r);

  read_required_families(&r, required_families_out, required_families_count_out);

  Chunk *chunk = read_chunk(&r, vm);
  fclose(r.f);

  validate_chunk(chunk, path);
  resolve_globals(vm, chunk, path);
  return chunk;
}

/* In-memory counterpart of creme_load -- see the Reader struct's own doc
 * comment above. Used by (creme bootstrap)'s icecreme-side `load-chunk-bytes`
 * builtin (bootstrap.c) to load a bytevector a running program just
 * computed (e.g. the self-hosted compiler's own compile-source-to-bytes
 * output) without ever touching the filesystem. */
Chunk *creme_load_from_bytes(VM *vm, const unsigned char *bytes, size_t len, char ***required_families_out, int *required_families_count_out) {
  Reader r = {0};
  r.path = "<bytevector>";
  r.buf = bytes;
  r.buf_len = len;

  check_magic_and_version(&r);

  read_required_families(&r, required_families_out, required_families_count_out);

  Chunk *chunk = read_chunk(&r, vm);
  validate_chunk(chunk, r.path);
  resolve_globals(vm, chunk, r.path);
  return chunk;
}
