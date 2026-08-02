/* Value model for the icecreme prototype — see icecreme/README.md for full scope.
 *
 * Deliberately NOT what a general Scheme VM would need: fixnums are plain
 * int64_t (no bignum promotion — an overflowing add/sub/mul still aborts,
 * see vm.c's num_add/num_sub/num_mul), plain-tagged struct (not NaN-boxed) for
 * debuggability. Rationals (T_RATIONAL, below) ARE arbitrary-precision,
 * backed by GMP's mpq_t — a narrower addition than a full numeric tower,
 * added specifically because spec/creme's own reader/compiler literal
 * tests need real exact rationals and complex numbers to exist at all (see
 * icecreme/README.md's "numeric tower" note for exactly what this does and
 * doesn't cover — plain T_INT is still fixnum-only). Every heap object
 * (pairs, vectors, closures, upvalues, output-string ports, the program's
 * own Chunk tree, T_RATIONAL/T_COMPLEX's own wrapper structs) is allocated
 * via Boehm GC (GC_MALLOC/GC_REALLOC — the same collector Crystal itself
 * uses) rather than a custom allocator, so a long-running program (an HTTP
 * server, not just a one-shot benchmark) doesn't grow unbounded. */
#ifndef CVM_VALUE_H
#define CVM_VALUE_H

#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>

#include <gmp.h>

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
                   * here to the constructor/predicate too, since icecreme's
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
             * compiler/compiler.sld's icecreme-expand-defmacro-form, which
             * does the actual expansion (bind params, compile+run body)
             * reentrant from C via cvm_apply. define-syntax (syntax-rules)
             * macros aren't covered by this -- see bootstrap.c's
             * bi_expand_if_macro for why that's a narrower, separate gap. */
  T_CONTINUATION, /* call/cc's own captured escape point -- ESCAPE-ONLY
             * (a one-shot, upward/non-reentrant continuation): invoking
             * one (dispatch_call/cvm_apply recognize this tag directly,
             * same as T_PARAMETER/T_RECORD_CALLABLE) longjmps straight
             * back to call/cc's own setjmp call site, unwinding any
             * pending dynamic-wind/parameterize actions along the way
             * (see vm.c's Continuation doc comment) -- NOT a real,
             * re-enterable continuation (no stack copying/CPS here, a
             * deliberate prototype-scope cut; invoking one again after
             * its own call/cc has already returned is undefined). */
  T_RATIONAL, /* an exact rational in lowest terms, arbitrary-precision
             * numerator/denominator via GMP's mpq_t (Rational, below) --
             * NEVER an integer or zero (vm.c's make_rational_from_mpq
             * collapses den==1 to a plain T_INT before a T_RATIONAL Value
             * is ever constructed, mirroring SchemeRational.make exactly,
             * see rational.cr). */
  T_COMPLEX,  /* real+imaginary, each itself a T_INT/T_RATIONAL/T_FLOAT
             * Value (Complex, below) -- NEVER a nested T_COMPLEX, and NEVER
             * constructed with an exact-zero imaginary part (vm.c's
             * make_complex collapses that case back to the bare real
             * Value), mirroring SchemeComplex.make exactly (complex.cr). */
} Tag;

/* RecordCallable kinds -- mirrors the real interpreter's split between an
 * ordinary constructor/predicate Builtin closure and the dedicated
 * RecordAccessor/RecordMutator Builtin subtypes (record.cr), collapsed
 * into one tagged struct + kind field here (same pattern as T_BOX's own
 * BOX_KIND_*) since icecreme has no closure-capturing Builtin representation. */
enum {
  RC_CTOR = 1,
  RC_PRED = 2,
  RC_ACCESSOR = 3,
  RC_MUTATOR = 4,
};

/* Box kinds — one per native module that wraps a foreign handle.
 * BOX_KIND_EOF is the odd one out: no foreign handle at all, just a
 * distinguishable singleton value for (eof-object)/(eof-object?) --
 * `ptr` is unused/NULL for it, see bi_eof_object in builtins.c. */
enum {
  BOX_KIND_HASHTABLE = 1,
  BOX_KIND_SQL = 2,
  BOX_KIND_MUX_ROUTER = 3,
  BOX_KIND_MUX_SERVER = 4,
  BOX_KIND_REGEX = 5,
  BOX_KIND_EOF = 6,
  BOX_KIND_CSV_READER = 7,
  BOX_KIND_CSV_WRITER = 8,
  BOX_KIND_TREELIST = 9,
  BOX_KIND_MUTABLE_TREELIST = 10,
  BOX_KIND_ACTOR_REF = 11,
  BOX_KIND_ACTOR_NODE = 12, /* actor.c Phase 3+: a start-node handle */
  BOX_KIND_BIGDECIMAL = 13,
  BOX_KIND_ENVIRONMENT = 14, /* bootstrap.c -- a genuinely separate child VM's
                              * own global table, used as (scheme eval)'s
                              * environment/null-environment/eval-2-arg target */
  BOX_KIND_FFI_LIB = 15,     /* ffi.c -- a dlopen(3) handle */
  BOX_KIND_FFI_FUNC = 16,    /* ffi.c -- a prepared libffi ffi_cif + fn ptr */
  BOX_KIND_FFI_POINTER = 17, /* ffi.c -- an opaque native pointer round-tripped
                              * through Scheme (an ffi-call argument/return
                              * value of type 'pointer) */
  BOX_KIND_PKEY = 18,        /* pkey.c -- an RSA/EC asymmetric key (see that
                              * file's own header comment for why it holds
                              * PEM text, never a live EVP_PKEY/RSA/EC_KEY*) */
  BOX_KIND_X509_CERT = 19,   /* x509.c -- an X.509 certificate (PEM text) */
  BOX_KIND_X509_CSR = 20,    /* x509.c -- a certificate signing request (PEM text) */
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
typedef struct Continuation Continuation;
typedef struct Rational Rational;
typedef struct Complex Complex;
typedef struct Upvalue Upvalue;
typedef struct VM VM;

typedef Value (*BuiltinFn)(VM *vm, Value *args, int nargs);

/* PROTOTYPE (not yet the committed layout — see icecreme/README.md's own
 * "Value/type model" discussion before assuming this is permanent):
 * `aux` holds T_STR/T_SYM's own length or T_BOX's own BOX_KIND_*,
 * living as a plain top-level int32_t alongside `tag` instead of nested
 * inside the union's own str/box sub-structs — the ONLY thing that used
 * to force the union past 8 bytes (a pointer + int sub-struct pads to
 * 16 for the pointer's own alignment). With the union back down to a
 * plain 8-byte word, `tag` (4) + `aux` (4) + `as` (8) = 16 bytes total,
 * down from 24 — see this file's own git history for the measured
 * before/after effect on real icecreme benchmarks. Unused (left as whatever
 * — never read) for every tag other than T_STR/T_SYM/T_BOX. */
struct Value {
  Tag tag;
  int32_t aux;
  union {
    int64_t i;
    double f;
    int b;
    const char *chars; /* T_STR/T_SYM — not NUL-terminated-guaranteed; use `aux` for length */
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
    Continuation *continuation;
    Rational *rational;
    Complex *cplx;
    BuiltinFn builtin;
    void *ptr; /* T_BOX — use `aux` for BOX_KIND_* */
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

/* PORT_KIND_STDOUT/PORT_KIND_STDIN are the two process-stream singletons
 * (see builtins.c's stdout_port_sentinel/stdin_port_sentinel) -- buf/len/
 * cap/pos/file are unused for those, since they read/write straight
 * through the literal `stdin`/`stdout` FILE* instead of a buffer or a
 * `file` field of their own (see builtins.c's read/write helpers'
 * kind-dispatch). PORT_KIND_OUTPUT_STRING uses buf/len/cap the same
 * grow-on-demand way this struct always has (buf the backing storage,
 * len the used prefix, cap the allocated size). PORT_KIND_INPUT_STRING
 * uses buf/len as an immutable (copied-in-at-open-input-string-time)
 * byte range plus `pos`, a forward-only read cursor into it -- cap is
 * unused there. PORT_KIND_INPUT_FILE/PORT_KIND_OUTPUT_FILE use `file`
 * (an fopen'd FILE*) instead of any of the above -- see
 * bi_open_input_file/bi_open_output_file. */
typedef enum {
  PORT_KIND_STDOUT,
  PORT_KIND_STDIN,
  PORT_KIND_OUTPUT_STRING,
  PORT_KIND_INPUT_STRING,
  PORT_KIND_INPUT_FILE,
  PORT_KIND_OUTPUT_FILE,
} PortKind;

/* `binary` distinguishes a bytevector-backed port (open-input-bytevector/
 * open-output-bytevector) from an otherwise-identical string-backed one
 * (open-input-string/open-output-string) -- mirrors native SchemePort's
 * own `binary?` flag exactly (base/bytevectors.cr's own header comment:
 * "distinguished only by the `binary` flag ... so read-u8/write-u8/
 * read-bytevector/etc. know not to UTF-8-decode"). Since icecreme's strings
 * are already plain byte buffers with no real UTF-8 decoding at all, a
 * binary port's buf/len/cap/pos mechanics are byte-for-byte identical to
 * a textual one's -- `binary` only changes which builtins accept the
 * port (binary-port?/textual-port?) and what Value tag read-u8/peek-u8/
 * get-output-bytevector wrap the bytes in (T_INT/T_BYTEVECTOR) vs.
 * read-char/peek-char/get-output-string's (T_CHAR/T_STR). Stdin/stdout/
 * file ports are always textual here (`binary` stays 0) -- open-input-
 * file/open-output-file have no binary variant in this prototype. */
struct Port {
  PortKind kind;
  char *buf;
  int len, cap;
  int pos;
  int closed;
  int binary;
  FILE *file;
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

/* call/cc's own captured escape point -- mirrors GuardHandler (vm.h)
 * almost exactly (same depth/jmp_buf-resume shape), since "escape all
 * the way back out to here" is the same operation either way; the only
 * real difference is call/cc's own jmp_buf lives in a GC-visible,
 * independently-allocated Value a program can pass around/store/call
 * later (bound by no particular lexical scope), where a GuardHandler is
 * always vm-internal and short-lived (installed/torn down by one
 * OP_PUSHHANDLER/OP_POPHANDLER pair). `depth`/`unwind_mark` are captured
 * at call/cc's OWN call time (mirrors GuardHandler's own `depth`);
 * `result` is set right before longjmp and read back right after the
 * corresponding setjmp returns nonzero -- there's no other way to carry
 * a rich Value through a raw C longjmp. */
struct Continuation {
  jmp_buf buf;
  int depth;
  int unwind_mark;
  Value result;
};

/* An arbitrary-precision exact rational, backed by GMP's mpq_t -- unlike
 * every other numeric tag here (T_INT is a plain machine int64_t, never
 * promoted to a bignum on overflow), a rational's OWN numerator/
 * denominator are arbitrary precision. Always canonicalized (mpq_
 * canonicalize: lowest terms, positive denominator) and never denominator
 * 1 -- see vm.c's make_rational_from_mpq for the single construction path
 * that upholds this. GMP's own allocator is redirected to GC_MALLOC/
 * GC_REALLOC (with a no-op free -- Boehm GC reclaims unreachable memory on
 * its own) at process start (main.c's mp_set_memory_functions call), so an
 * mpq_t's internal limbs are reclaimed the same way as every other heap
 * value here, never leaked. */
struct Rational {
  mpq_t q;
};

/* R7RS complex -- just two real components, mirrors SchemeComplex exactly
 * (complex.cr): real/imag are each a T_INT/T_RATIONAL/T_FLOAT Value, never
 * a nested T_COMPLEX. Only ever constructed via vm.c's make_complex, which
 * collapses to the bare real Value when imag is an exact zero (matching
 * SchemeComplex.make's own collapse rule) -- so a genuine T_COMPLEX Value
 * always has a non-exact-zero imaginary part. */
struct Complex {
  Value real;
  Value imag;
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
  v.as.chars = chars;
  v.aux = len;
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

static inline Value v_continuation(Continuation *k) {
  Value v;
  v.tag = T_CONTINUATION;
  v.as.continuation = k;
  return v;
}

/* Raw wrap only -- no reduce-to-lowest-terms/collapse-to-int logic here
 * (that's vm.c's make_rational_from_mpq's job); callers elsewhere should
 * always go through that, not construct a T_RATIONAL directly. */
static inline Value v_rational(Rational *r) {
  Value v;
  v.tag = T_RATIONAL;
  v.as.rational = r;
  return v;
}

/* Raw wrap only -- no exact-zero-imaginary collapse here (that's vm.c's
 * make_complex's job); callers elsewhere should always go through that. */
static inline Value v_complex(Complex *c) {
  Value v;
  v.tag = T_COMPLEX;
  v.as.cplx = c;
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
  v.as.ptr = ptr;
  v.aux = kind;
  return v;
}

/* Only #f is falsy — every other value (including '()) is truthy, per
 * R7RS/this project's own Creme.truthy?. */
static inline int v_falsy(Value v) {
  return v.tag == T_BOOL && !v.as.b;
}

#endif
