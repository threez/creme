/* Value model for the cvm prototype — see cvm/README.md for full scope.
 *
 * Deliberately NOT what a general Scheme VM would need: fixnums (int64_t) +
 * doubles only (no bignum/rational/complex — this bench never overflows
 * int64), plain-tagged struct (not NaN-boxed) for debuggability. Every heap
 * object (pairs, vectors, closures, upvalues, output-string ports, the
 * program's own Chunk tree) is allocated via Boehm GC (GC_MALLOC/
 * GC_REALLOC — the same collector Crystal itself uses) rather than a
 * custom allocator, so a long-running program (an HTTP server, not just a
 * one-shot benchmark) doesn't grow unbounded. */
#ifndef CVM_VALUE_H
#define CVM_VALUE_H

#include <stdint.h>

typedef enum {
  T_NIL,
  T_BOOL,
  T_INT,
  T_FLOAT,
  T_SYM,    /* only ever loaded into a register and discarded (see
             * cvm_serializer.cr's comment on the "define returns its own
             * name" idiom) — never inspected at runtime. */
  T_STR,    /* mutable string (string-set!, as of Group C) — `chars` is
             * declared `const` only to stop most code from writing
             * through it by accident; the buffer itself is always a
             * freshly GC_MALLOC'd, uniquely-owned copy, NEVER a pointer
             * into another Value's buffer, a substring offset, or a C
             * string literal (which would segfault on the first
             * string-set!) — see builtins.c/strings.c/mux.c/sql.c for
             * everywhere that invariant is upheld (copy_bytes/v_gcstr/
             * v_litstr helpers). T_SYM below reuses this same struct
             * shape but is never mutated through it. */
  T_CHAR,   /* a Unicode codepoint (stored in .i, like T_INT) — string-ref's
             * result type and Op::CaseDispatch's char-keyed clauses. */
  T_PAIR,
  T_VECTOR,
  T_BYTEVECTOR, /* a mutable buffer of raw bytes — from the const pool
                 * (TAG_BLOB), make-bytevector, or bytevector. */
  T_PROMISE,    /* delay/delay-force's own wrapped 0-arg thunk, memoized on
                 * first force — see builtins.c's `force`. */
  T_VALUES,     /* a multiple-values carrier produced by `values` (0 or 2+
                 * args — a single arg is just returned as itself, never
                 * wrapped) and unpacked by Op::Destructure/
                 * call-with-values. Never appears as a "real" Scheme value
                 * anywhere else — see Op::Destructure's own doc comment. */
  T_PORT,   /* open-output-string's growable buffer. */
  T_CLOSURE,
  T_CASE_CLOSURE, /* case-lambda -- an ordered array of Closures, one per
                   * clause; a call picks the first whose arity accepts
                   * the argument count (see vm.c's dispatch_call). */
  T_RECORD_TYPE,  /* define-record-type's own type descriptor -- one fresh
                   * instance per invocation (mirrors SchemeRecordType),
                   * so distinct define-record-type forms are always
                   * disjoint even if they share a type name. */
  T_RECORD,       /* a record instance -- a type pointer (compared by
                   * IDENTITY, not name, by the type's own predicate) plus
                   * a positional fields array (mirrors SchemeRecord). */
  T_RECORD_CALLABLE, /* a record type's generated constructor/predicate/
                   * accessor/mutator -- see RC_* kinds and RecordCallable
                   * below; `dispatch_call`/`cvm_apply` recognize this tag
                   * directly (mirrors how the real VM's own dispatch_call
                   * special-cases RecordAccessor/RecordMutator, extended
                   * here to the constructor/predicate too, since cvm's
                   * plain BuiltinFn function-pointer type has nowhere to
                   * stash per-invocation captured state like a record
                   * type/field index the way a real Crystal closure can). */
  T_BUILTIN,
  T_PARAMETER, /* make-parameter/parameterize -- calling it with 0 args
                * returns its current value (dispatch_call/cvm_apply
                * recognize this tag directly, same as T_RECORD_CALLABLE),
                * mirrors SchemeParameter exactly. */
  T_BOX,    /* opaque native handle -- a hash table, sql connection, mux
             * router/server, etc. `kind` (BOX_KIND_*) disambiguates which;
             * mirrors the real interpreter's SchemeBox. */
  T_MACRO,  /* a defmacro's raw, unexpanded (defmacro name (params...)
             * body...) form, bound under `name` in vm->globals by
             * Op::HelperForm's kind==4 case -- reuses .as.pair (the tag
             * alone distinguishes it from an ordinary T_PAIR value bound
             * to the same name, e.g. `(define name '(defmacro ...))`).
             * Lets expand-if-macro (bootstrap.c) recognize a defmacro
             * EXPORTED from a library compiled straight to bytecode
             * (Crystal natively, or this project's own self-hosted
             * compiler ahead of time) as a real runtime macro, the same
             * way Crystal's own Macro/env-bound value does -- see
             * bootstrap.c's own header comment and modules/creme/
             * compiler/compiler.sld's cvm-expand-defmacro-form, which
             * does the actual expansion (bind params, compile+run body)
             * reentrant from C via cvm_apply. define-syntax (syntax-rules)
             * macros aren't covered by this -- see bootstrap.c's
             * bi_expand_if_macro for why that's a narrower, separate gap. */
} Tag;

/* RecordCallable kinds -- mirrors the real interpreter's split between an
 * ordinary constructor/predicate Builtin closure and the dedicated
 * RecordAccessor/RecordMutator Builtin subtypes (record.cr), collapsed
 * into one tagged struct + kind field here (same pattern as T_BOX's own
 * BOX_KIND_*) since cvm has no closure-capturing Builtin representation. */
enum {
  RC_CTOR = 1,
  RC_PRED = 2,
  RC_ACCESSOR = 3,
  RC_MUTATOR = 4,
};

/* Box kinds — one per native module that wraps a foreign handle. */
enum {
  BOX_KIND_HASHTABLE = 1,
  BOX_KIND_SQL = 2,
  BOX_KIND_MUX_ROUTER = 3,
  BOX_KIND_MUX_SERVER = 4,
  BOX_KIND_REGEX = 5,
};

typedef struct Value Value;
typedef struct Pair Pair;
typedef struct Vector Vector;
typedef struct Bytevector Bytevector;
typedef struct Promise Promise;
typedef struct MultiValues MultiValues;
typedef struct Port Port;
typedef struct Closure Closure;
typedef struct CaseClosure CaseClosure;
typedef struct RecordType RecordType;
typedef struct SchemeRecord SchemeRecord;
typedef struct RecordCallable RecordCallable;
typedef struct Parameter Parameter;
typedef struct Upvalue Upvalue;
typedef struct VM VM;

typedef Value (*BuiltinFn)(VM *vm, Value *args, int nargs);

struct Value {
  Tag tag;
  union {
    int64_t i;
    double f;
    int b;
    struct {
      const char *chars; /* not NUL-terminated-guaranteed; use len */
      int len;
    } str;
    Pair *pair;
    Vector *vec;
    Bytevector *bv;
    Promise *promise;
    MultiValues *values;
    Port *port;
    Closure *closure;
    CaseClosure *case_closure;
    RecordType *record_type;
    SchemeRecord *record;
    RecordCallable *record_callable;
    Parameter *parameter;
    BuiltinFn builtin;
    struct {
      void *ptr;
      int kind; /* BOX_KIND_* */
    } box;
  } as;
};

struct Pair {
  Value car, cdr;
};

struct Vector {
  Value *items;
  int len;
};

struct Bytevector {
  unsigned char *bytes;
  int len;
};

/* `thunk` is a 0-arg Closure/Builtin, invoked (and its result cached) at
 * most once — see builtins.c's `force`. Mirrors the real interpreter's
 * SchemePromise exactly (thunk_closure + forced?/cached value). */
struct Promise {
  Value thunk;
  int forced;
  Value cached;
};

struct Port {
  char *buf;
  int len, cap;
};

struct MultiValues {
  Value *items;
  int len;
};

/* case-lambda -- `clauses[i]` is a fully-built Closure per clause, in
 * source order; dispatch_call (vm.c) picks the first whose arity accepts
 * the call's argument count, mirroring BytecodeCaseClosure#select_clause
 * (bytecode_closure.cr) exactly. */
struct CaseClosure {
  Closure **clauses;
  int n_clauses;
};

/* define-record-type's type descriptor -- mirrors SchemeRecordType
 * exactly (record.cr): `field_names[i]` is field i's declared name, in
 * declaration order (this order IS the record's own field-index space --
 * every RecordCallable's field_index and every SchemeRecord's fields
 * array line up against it). `name`/`field_names` are plain T_SYM Values
 * (reusing their existing GC-owned, already-correctly-lengthed .as.str
 * storage) rather than separately-copied C strings. */
struct RecordType {
  Value name;
  Value *field_names;
  int n_fields;
};

/* mirrors SchemeRecord (record.cr): `type` is compared by pointer
 * identity (never by name) everywhere a predicate/accessor/mutator
 * checks "is this really one of my own records" -- see RC_PRED/
 * RC_ACCESSOR/RC_MUTATOR in vm.c's dispatch_call. */
struct SchemeRecord {
  RecordType *type;
  Value *fields;
};

/* One of a record type's generated constructor/predicate/accessor/
 * mutator -- `kind` (RC_*) says which; only the fields that kind actually
 * needs are meaningful (ctor uses ctor_field_indices/n_ctor_args,
 * predicate uses only `type`, accessor/mutator use `field_index`). */
struct RecordCallable {
  RecordType *type;
  int kind;
  int *ctor_field_indices; /* RC_CTOR only: ctor_field_indices[i] = index
                             * into type->field_names for the i-th
                             * constructor argument. */
  int n_ctor_args;         /* RC_CTOR only. */
  int field_index;         /* RC_ACCESSOR/RC_MUTATOR only. */
};

/* make-parameter's own value -- mirrors SchemeParameter exactly
 * (`converter`, if present, is applied to a parameterize'd newval before
 * installing it -- see Op::ParamPush). */
struct Parameter {
  Value value;
  Value converter;
  int has_converter;
};

static inline Value v_nil(void) {
  Value v;
  v.tag = T_NIL;
  return v;
}

static inline Value v_bool(int b) {
  Value v;
  v.tag = T_BOOL;
  v.as.b = b != 0;
  return v;
}

static inline Value v_int(int64_t i) {
  Value v;
  v.tag = T_INT;
  v.as.i = i;
  return v;
}

static inline Value v_float(double f) {
  Value v;
  v.tag = T_FLOAT;
  v.as.f = f;
  return v;
}

static inline Value v_str(const char *chars, int len) {
  Value v;
  v.tag = T_STR;
  v.as.str.chars = chars;
  v.as.str.len = len;
  return v;
}

static inline Value v_sym(const char *chars, int len) {
  Value v = v_str(chars, len);
  v.tag = T_SYM;
  return v;
}

static inline Value v_char(int64_t codepoint) {
  Value v;
  v.tag = T_CHAR;
  v.as.i = codepoint;
  return v;
}

static inline Value v_pair(Pair *p) {
  Value v;
  v.tag = T_PAIR;
  v.as.pair = p;
  return v;
}

/* `form` is the raw (defmacro name (params...) body...) Pair -- see
 * T_MACRO's own doc comment above. */
static inline Value v_macro(Pair *form) {
  Value v;
  v.tag = T_MACRO;
  v.as.pair = form;
  return v;
}

static inline Value v_vector(Vector *vec) {
  Value v;
  v.tag = T_VECTOR;
  v.as.vec = vec;
  return v;
}

static inline Value v_bytevector(Bytevector *bv) {
  Value v;
  v.tag = T_BYTEVECTOR;
  v.as.bv = bv;
  return v;
}

static inline Value v_promise(Promise *p) {
  Value v;
  v.tag = T_PROMISE;
  v.as.promise = p;
  return v;
}

static inline Value v_values(MultiValues *mv) {
  Value v;
  v.tag = T_VALUES;
  v.as.values = mv;
  return v;
}

static inline Value v_port(Port *p) {
  Value v;
  v.tag = T_PORT;
  v.as.port = p;
  return v;
}

static inline Value v_closure(Closure *c) {
  Value v;
  v.tag = T_CLOSURE;
  v.as.closure = c;
  return v;
}

static inline Value v_case_closure(CaseClosure *cc) {
  Value v;
  v.tag = T_CASE_CLOSURE;
  v.as.case_closure = cc;
  return v;
}

static inline Value v_record_type(RecordType *rt) {
  Value v;
  v.tag = T_RECORD_TYPE;
  v.as.record_type = rt;
  return v;
}

static inline Value v_record(SchemeRecord *r) {
  Value v;
  v.tag = T_RECORD;
  v.as.record = r;
  return v;
}

static inline Value v_record_callable(RecordCallable *rc) {
  Value v;
  v.tag = T_RECORD_CALLABLE;
  v.as.record_callable = rc;
  return v;
}

static inline Value v_parameter(Parameter *p) {
  Value v;
  v.tag = T_PARAMETER;
  v.as.parameter = p;
  return v;
}

static inline Value v_builtin(BuiltinFn fn) {
  Value v;
  v.tag = T_BUILTIN;
  v.as.builtin = fn;
  return v;
}

static inline Value v_box(void *ptr, int kind) {
  Value v;
  v.tag = T_BOX;
  v.as.box.ptr = ptr;
  v.as.box.kind = kind;
  return v;
}

/* Only #f is falsy — every other value (including '()) is truthy, per
 * R7RS/this project's own Scheme.truthy?. */
static inline int v_falsy(Value v) {
  return v.tag == T_BOOL && !v.as.b;
}

#endif
