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
  T_STR,    /* immutable string — from the const pool, or produced fresh by
             * get-output-string. */
  T_CHAR,   /* a Unicode codepoint (stored in .i, like T_INT) — string-ref's
             * result type and Op::CaseDispatch's char-keyed clauses. */
  T_PAIR,
  T_VECTOR,
  T_PORT,   /* open-output-string's growable buffer. */
  T_CLOSURE,
  T_BUILTIN,
  T_BOX,    /* opaque native handle -- a hash table, sql connection, mux
             * router/server, etc. `kind` (BOX_KIND_*) disambiguates which;
             * mirrors the real interpreter's SchemeBox. */
} Tag;

/* Box kinds — one per native module that wraps a foreign handle. */
enum {
  BOX_KIND_HASHTABLE = 1,
  BOX_KIND_SQL = 2,
  BOX_KIND_MUX_ROUTER = 3,
  BOX_KIND_MUX_SERVER = 4,
};

typedef struct Value Value;
typedef struct Pair Pair;
typedef struct Vector Vector;
typedef struct Port Port;
typedef struct Closure Closure;
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
    Port *port;
    Closure *closure;
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

struct Port {
  char *buf;
  int len, cap;
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

static inline Value v_vector(Vector *vec) {
  Value v;
  v.tag = T_VECTOR;
  v.as.vec = vec;
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
