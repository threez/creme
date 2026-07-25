/* The builtins bench/creme.scm actually calls as plain (non-fused) global
 * procedures — see cvm/README.md's "builtins actually called" list. Nothing
 * else is registered; calling any other name aborts with "unbound
 * variable" (see vm.c's OP_GETGLOBAL and CallGlobal arms). */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <gc.h>

#include "vm.h"

static void port_buf_grow(Port *p, int extra) {
  if (p->len + extra > p->cap) {
    p->cap = (p->cap ? p->cap * 2 : 64);
    while (p->cap < p->len + extra) p->cap *= 2;
    p->buf = GC_REALLOC(p->buf, (size_t)p->cap);
  }
}

static Value bi_make_vector(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_INT) cvm_abort("make-vector: expected a length");
  int64_t n = args[0].as.i;
  Value fill = nargs >= 2 ? args[1] : v_bool(0);
  Vector *vec = GC_MALLOC(sizeof(Vector));
  vec->len = (int)n;
  vec->items = GC_MALLOC(sizeof(Value) * (size_t)(n ? n : 1));
  for (int64_t i = 0; i < n; i++) vec->items[i] = fill;
  return v_vector(vec);
}

static Value bi_make_bytevector(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_INT) cvm_abort("make-bytevector: expected a length");
  int64_t n = args[0].as.i;
  int64_t fill = nargs >= 2 && args[1].tag == T_INT ? args[1].as.i : 0;
  if (fill < 0 || fill > 255) cvm_abort("make-bytevector: fill value out of byte range");
  Bytevector *bv = GC_MALLOC(sizeof(Bytevector));
  bv->len = (int)n;
  bv->bytes = GC_MALLOC((size_t)(n ? n : 1));
  for (int64_t i = 0; i < n; i++) bv->bytes[i] = (unsigned char)fill;
  return v_bytevector(bv);
}

static Value bi_bytevector(VM *vm, Value *args, int nargs) {
  (void)vm;
  Bytevector *bv = GC_MALLOC(sizeof(Bytevector));
  bv->len = nargs;
  bv->bytes = GC_MALLOC((size_t)(nargs ? nargs : 1));
  for (int i = 0; i < nargs; i++) {
    if (args[i].tag != T_INT || args[i].as.i < 0 || args[i].as.i > 255) cvm_abort("bytevector: byte out of range");
    bv->bytes[i] = (unsigned char)args[i].as.i;
  }
  return v_bytevector(bv);
}

static Value bi_bytevector_length(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)nargs;
  if (args[0].tag != T_BYTEVECTOR) cvm_abort("bytevector-length: not a bytevector");
  return v_int(args[0].as.bv->len);
}

static Value bi_bytevector_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)nargs;
  return v_bool(args[0].tag == T_BYTEVECTOR);
}

/* force: mirrors Interpreter#force's own memoization exactly (see
 * src/scheme/value/values.cr's SchemePromise) — if `args[0]` isn't itself a
 * promise, R7RS says force may just return it unchanged. Only ever invokes
 * the wrapped 0-arg thunk once; the result is cached in place so a second
 * force on the same promise is free. delay-force's own re-entrant "the
 * thunk itself returns another promise, keep forcing" chaining isn't
 * implemented (this prototype's `delay-force` compiles to the exact same
 * MakePromise op as `delay` — see opcode.cr), so a delay-force thunk that
 * returns a promise here just yields that inner promise value itself
 * rather than transparently forcing through it. */
static Value bi_force(VM *vm, Value *args, int nargs) {
  (void)nargs;
  if (args[0].tag != T_PROMISE) return args[0];
  Promise *p = args[0].as.promise;
  if (!p->forced) {
    p->cached = cvm_apply(vm, p->thunk, NULL, 0);
    p->forced = 1;
  }
  return p->cached;
}

static Value bi_promise_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)nargs;
  return v_bool(args[0].tag == T_PROMISE);
}

/* +, -, *, /, and the comparisons as REAL, ordinary global procedures -- never needed
 * for a program compiled by the REAL Crystal analyzer (its own PRIM_OPS
 * table fuses a 2-arg call to one of these names straight into an Add/
 * Sub/etc. op at compile time, see cvm/README.md's "builtins actually
 * called" note), but the SELF-HOSTED compiler (modules/creme/compiler/
 * compiler.sld) does no such fusion -- it compiles every call, including
 * these, as an ordinary CallGlobal, so anything IT compiles (e.g. a REPL
 * line) needs these names to genuinely exist. Reuse vm.c's own
 * num_add/num_sub/num_mul/num_lt/.../as_double so the semantics
 * (int/float promotion, overflow aborts) are identical to the fused
 * fast-path ops, not a second implementation to keep in sync. */
static Value bi_plus(VM *vm, Value *args, int nargs) {
  (void)vm;
  Value acc = v_int(0);
  for (int i = 0; i < nargs; i++) acc = num_add(acc, args[i]);
  return acc;
}

static Value bi_minus(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("-: expected at least 1 argument");
  if (nargs == 1) return num_sub(v_int(0), args[0]);
  Value acc = args[0];
  for (int i = 1; i < nargs; i++) acc = num_sub(acc, args[i]);
  return acc;
}

static Value bi_star(VM *vm, Value *args, int nargs) {
  (void)vm;
  Value acc = v_int(1);
  for (int i = 0; i < nargs; i++) acc = num_mul(acc, args[i]);
  return acc;
}

/* No rational tower here (see cvm/README.md's "Value/type model"), so an
 * unevenly-divided integer division falls back to a float, matching this
 * prototype's existing "int+float only" scope everywhere else -- only
 * returns an exact int back when every operand was an int AND the
 * mathematical result happens to be a whole number. */
static Value bi_slash(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("/: expected at least 1 argument");
  Value first = nargs == 1 ? v_int(1) : args[0];
  int start = nargs == 1 ? 0 : 1;
  double acc = as_double(first, "/");
  int all_int = first.tag == T_INT;
  for (int i = start; i < nargs; i++) {
    double d = as_double(args[i], "/");
    if (d == 0.0) cvm_abort("/: division by zero");
    acc /= d;
    if (args[i].tag != T_INT) all_int = 0;
  }
  if (all_int && acc == floor(acc) && fabs(acc) < 9.2e18) return v_int((int64_t)acc);
  return v_float(acc);
}

static Value bi_num_lt(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("<: expected at least 1 argument");
  for (int i = 1; i < nargs; i++)
    if (!num_lt(args[i - 1], args[i])) return v_bool(0);
  return v_bool(1);
}

static Value bi_num_gt(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort(">: expected at least 1 argument");
  for (int i = 1; i < nargs; i++)
    if (!num_gt(args[i - 1], args[i])) return v_bool(0);
  return v_bool(1);
}

static Value bi_num_le(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("<=: expected at least 1 argument");
  for (int i = 1; i < nargs; i++)
    if (!num_le(args[i - 1], args[i])) return v_bool(0);
  return v_bool(1);
}

static Value bi_num_ge(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort(">=: expected at least 1 argument");
  for (int i = 1; i < nargs; i++)
    if (!num_ge(args[i - 1], args[i])) return v_bool(0);
  return v_bool(1);
}

static Value bi_num_eq(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("=: expected at least 1 argument");
  for (int i = 1; i < nargs; i++)
    if (!num_eq(args[i - 1], args[i])) return v_bool(0);
  return v_bool(1);
}

/* quotient/remainder truncate toward zero (R7RS) -- exactly what C's own
 * `/`/`%` already do for integers, so no extra logic needed beyond a
 * zero-divisor check. modulo floors instead (result's sign matches the
 * divisor, not the dividend) -- needed by the self-hosted compiler's own
 * (creme bytecode) int->le-bytes for correct full-range little-endian
 * encoding of negative integers (see modules/creme/bytecode.sld's own
 * comment on exactly this). */
static Value bi_quotient(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 2 || args[0].tag != T_INT || args[1].tag != T_INT) cvm_abort("quotient: expected two integers");
  if (args[1].as.i == 0) cvm_abort("quotient: division by zero");
  return v_int(args[0].as.i / args[1].as.i);
}

static Value bi_remainder(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 2 || args[0].tag != T_INT || args[1].tag != T_INT) cvm_abort("remainder: expected two integers");
  if (args[1].as.i == 0) cvm_abort("remainder: division by zero");
  return v_int(args[0].as.i % args[1].as.i);
}

static Value bi_modulo(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 2 || args[0].tag != T_INT || args[1].tag != T_INT) cvm_abort("modulo: expected two integers");
  int64_t b = args[1].as.i;
  if (b == 0) cvm_abort("modulo: division by zero");
  int64_t r = args[0].as.i % b;
  if (r != 0 && ((r < 0) != (b < 0))) r += b;
  return v_int(r);
}

static Value bi_current_second(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)args;
  (void)nargs;
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return v_float((double)ts.tv_sec + (double)ts.tv_nsec / 1e9);
}

/* Mirrors SchemeFloat#to_display (values.cr): whole floats print as "N.0",
 * everything else via a round-trip-safe %.17g — not byte-identical to
 * Crystal's shortest-round-trip formatter, but this bench only ever
 * displays timings, never string-compares them. */
/* `display` convention throughout (strings/chars print their raw content,
 * not a re-readable `write`-style quoted/escaped form) — this prototype has
 * no separate (scheme write) `write` builtin, only `display`, matching what
 * bench/creme.scm and the demo-todo app both actually call. */
static void print_value(FILE *out, Value v) {
  switch (v.tag) {
  case T_INT:
    fprintf(out, "%lld", (long long)v.as.i);
    break;
  case T_FLOAT: {
    double f = v.as.f;
    if (fabs(f) < 1e15 && f == (double)(int64_t)f) {
      fprintf(out, "%lld.0", (long long)f);
    } else {
      fprintf(out, "%.17g", f);
    }
    break;
  }
  case T_STR:
    fwrite(v.as.str.chars, 1, (size_t)v.as.str.len, out);
    break;
  case T_SYM:
    fwrite(v.as.str.chars, 1, (size_t)v.as.str.len, out);
    break;
  case T_CHAR: {
    /* Codepoints are stored/produced byte-wise in this prototype (see
     * string-ref's own comment) — a single fputc mirrors that scope. */
    fputc((int)v.as.i, out);
    break;
  }
  case T_BOOL:
    fputs(v.as.b ? "#t" : "#f", out);
    break;
  case T_NIL:
    fputs("()", out);
    break;
  case T_PAIR: {
    fputc('(', out);
    Value cur = v;
    int first = 1;
    while (cur.tag == T_PAIR) {
      if (!first) fputc(' ', out);
      first = 0;
      print_value(out, cur.as.pair->car);
      cur = cur.as.pair->cdr;
    }
    if (cur.tag != T_NIL) {
      fputs(" . ", out);
      print_value(out, cur);
    }
    fputc(')', out);
    break;
  }
  case T_VECTOR: {
    fputs("#(", out);
    for (int i = 0; i < v.as.vec->len; i++) {
      if (i) fputc(' ', out);
      print_value(out, v.as.vec->items[i]);
    }
    fputc(')', out);
    break;
  }
  case T_BYTEVECTOR:
    /* Mirrors SchemeBlob#to_display exactly (values.cr) — the opaque
     * "#<blob:N bytes>" form, not R7RS's #u8(...) write-style rendering
     * (this prototype has no separate `write`, only `display` — see this
     * function's own header comment). */
    fprintf(out, "#<blob:%d bytes>", v.as.bv->len);
    break;
  case T_PROMISE:
    fprintf(out, "#<promise%s>", v.as.promise->forced ? " forced" : "");
    break;
  case T_CLOSURE:
  case T_CASE_CLOSURE:
  case T_RECORD_CALLABLE:
    fputs("#<procedure>", out);
    break;
  case T_PARAMETER:
    fputs("#<parameter>", out);
    break;
  case T_RECORD_TYPE:
    fputs("#<record-type:", out);
    fwrite(v.as.record_type->name.as.str.chars, 1, (size_t)v.as.record_type->name.as.str.len, out);
    fputc('>', out);
    break;
  case T_RECORD: {
    /* Mirrors SchemeRecord#to_display exactly (record.cr): "#<name
     * field=val field=val ...>". */
    RecordType *rt = v.as.record->type;
    fputc('#', out);
    fputc('<', out);
    fwrite(rt->name.as.str.chars, 1, (size_t)rt->name.as.str.len, out);
    for (int i = 0; i < rt->n_fields; i++) {
      fputc(' ', out);
      fwrite(rt->field_names[i].as.str.chars, 1, (size_t)rt->field_names[i].as.str.len, out);
      fputc('=', out);
      print_value(out, v.as.record->fields[i]);
    }
    fputc('>', out);
    break;
  }
  case T_BUILTIN:
    fputs("#<procedure>", out);
    break;
  case T_PORT:
    fputs("#<port>", out);
    break;
  case T_BOX:
    fputs("#<native-object>", out);
    break;
  default:
    cvm_abort("display: unsupported value type in this prototype");
  }
}

static Value bi_display(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("display: expected an argument");
  print_value(stdout, args[0]);
  return v_nil();
}

static Value bi_newline(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)args;
  (void)nargs;
  fputc('\n', stdout);
  return v_nil();
}

static Value bi_open_output_string(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)args;
  (void)nargs;
  Port *p = GC_MALLOC(sizeof(Port));
  return v_port(p);
}

static Value bi_get_output_string(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_PORT) cvm_abort("get-output-string: expected a port");
  Port *p = args[0].as.port;
  /* Copies out (matches SchemeStr's own value-semantics — a fresh immutable
   * string each call), even though nothing in this bench mutates the port
   * afterward. GC_MALLOC'd like every other heap value here. */
  char *copy = GC_MALLOC((size_t)p->len);
  memcpy(copy, p->buf, (size_t)p->len);
  return v_str(copy, p->len);
}

static Value bi_string_length(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) cvm_abort("string-length: expected a string");
  return v_int(args[0].as.str.len);
}

/* Sentinel Port identifying (current-output-port) — write-string/display
 * special-case it to write straight to stdout rather than buffering (there's
 * nothing to later get-output-string out of "the real terminal"). Identified
 * by pointer, not content (an ordinary output-string port also starts as an
 * all-zero Port). */
static Port stdout_port_sentinel;

static Value bi_current_output_port(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)args;
  (void)nargs;
  return v_port(&stdout_port_sentinel);
}

static Value bi_write_string(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2 || args[0].tag != T_STR || args[1].tag != T_PORT) cvm_abort("write-string: expected (string port)");
  Port *p = args[1].as.port;
  if (p == &stdout_port_sentinel) {
    fwrite(args[0].as.str.chars, 1, (size_t)args[0].as.str.len, stdout);
    return v_nil();
  }
  port_buf_grow(p, args[0].as.str.len);
  memcpy(p->buf + p->len, args[0].as.str.chars, (size_t)args[0].as.str.len);
  p->len += args[0].as.str.len;
  return v_nil();
}

static Value bi_reverse(VM *vm, Value *args, int nargs) {
  if (nargs < 1) cvm_abort("reverse: expected a list");
  Value result = v_nil();
  Value cur = args[0];
  while (cur.tag == T_PAIR) {
    result = cvm_cons(vm, cur.as.pair->car, result);
    cur = cur.as.pair->cdr;
  }
  if (cur.tag != T_NIL) cvm_abort("reverse: improper list");
  return result;
}

static Value bi_length(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("length: expected a list");
  int64_t n = 0;
  Value cur = args[0];
  while (cur.tag == T_PAIR) {
    n++;
    cur = cur.as.pair->cdr;
  }
  if (cur.tag != T_NIL) cvm_abort("length: improper list");
  return v_int(n);
}

/* ---- equal? ----
 * cvm_eqv (vm.c) already handles every scalar/identity-compared tag;
 * equal? only adds structural recursion for pairs/vectors. */
static int cvm_equal(Value a, Value b) {
  if (a.tag != b.tag) return 0;
  switch (a.tag) {
  case T_PAIR:
    return cvm_equal(a.as.pair->car, b.as.pair->car) && cvm_equal(a.as.pair->cdr, b.as.pair->cdr);
  case T_VECTOR:
    if (a.as.vec->len != b.as.vec->len) return 0;
    for (int i = 0; i < a.as.vec->len; i++) {
      if (!cvm_equal(a.as.vec->items[i], b.as.vec->items[i])) return 0;
    }
    return 1;
  default:
    return cvm_eqv(a, b);
  }
}

/* ---- predicates / eq-family (also registered as ordinary procedures for
 * higher-order use, e.g. (map pair? lst) — most of these are normally
 * fused into their own op by the compiler, but a bare reference to the
 * name as a value still needs a real global binding). ---- */
static Value bi_not(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("not: expected an argument"); return v_bool(v_falsy(args[0])); }
static Value bi_pair_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("pair?: expected an argument"); return v_bool(args[0].tag == T_PAIR); }
static Value bi_null_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("null?: expected an argument"); return v_bool(args[0].tag == T_NIL); }
/* Walks cdr's until a non-pair; #t iff that's T_NIL -- mirrors the real
 * interpreter's own Scheme.proper_list? (helpers.cr) exactly, including
 * NOT being cycle-safe (a genuinely circular list would infinite-loop
 * here too, same as there -- a known, already-accepted simplification in
 * the reference implementation this isn't introducing anything new). */
static Value bi_list_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("list?: expected an argument");
  Value cur = args[0];
  while (cur.tag == T_PAIR) cur = cur.as.pair->cdr;
  return v_bool(cur.tag == T_NIL);
}
static Value bi_boolean_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("boolean?: expected an argument"); return v_bool(args[0].tag == T_BOOL); }
static Value bi_symbol_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("symbol?: expected an argument"); return v_bool(args[0].tag == T_SYM); }
static Value bi_string_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("string?: expected an argument"); return v_bool(args[0].tag == T_STR); }
static Value bi_vector_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("vector?: expected an argument"); return v_bool(args[0].tag == T_VECTOR); }

/* vector-ref/-set!/-length, string-ref/-set!, bytevector-u8-ref/-set! as
 * REAL global procedures -- same story as +/-/cadr/etc. above: a program
 * the real analyzer compiles never needs these (its PRIM_OPS table fuses
 * a call site straight into VecRef/VecSet/StrRef/etc.), but the self-
 * hosted compiler does no such fusion, so anything it compiles needs
 * these to genuinely exist. Semantics mirror the fused ops' own bounds
 * checks exactly (vm.c's OP_VECREF/OP_VECSET/etc.). */
static Value bi_vector_ref(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 2 || args[0].tag != T_VECTOR || args[1].tag != T_INT) cvm_abort("vector-ref: expected (vector index)");
  int idx = (int)args[1].as.i;
  if (idx < 0 || idx >= args[0].as.vec->len) cvm_abort("vector-ref: index %d out of range", idx);
  return args[0].as.vec->items[idx];
}

static Value bi_vector_set(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 3 || args[0].tag != T_VECTOR || args[1].tag != T_INT) cvm_abort("vector-set!: expected (vector index value)");
  int idx = (int)args[1].as.i;
  if (idx < 0 || idx >= args[0].as.vec->len) cvm_abort("vector-set!: index %d out of range", idx);
  args[0].as.vec->items[idx] = args[2];
  return v_nil();
}

static Value bi_vector_length(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 1 || args[0].tag != T_VECTOR) cvm_abort("vector-length: expected a vector");
  return v_int(args[0].as.vec->len);
}

static Value bi_string_ref(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 2 || args[0].tag != T_STR || args[1].tag != T_INT) cvm_abort("string-ref: expected (string index)");
  int idx = (int)args[1].as.i;
  if (idx < 0 || idx >= args[0].as.str.len) cvm_abort("string-ref: index %d out of range", idx);
  return v_char((unsigned char)args[0].as.str.chars[idx]);
}

static Value bi_string_set(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 3 || args[0].tag != T_STR || args[1].tag != T_INT || args[2].tag != T_CHAR) cvm_abort("string-set!: expected (string index char)");
  int idx = (int)args[1].as.i;
  if (idx < 0 || idx >= args[0].as.str.len) cvm_abort("string-set!: index %d out of range", idx);
  ((char *)args[0].as.str.chars)[idx] = (char)args[2].as.i;
  return v_nil();
}

static Value bi_bytevector_u8_ref(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 2 || args[0].tag != T_BYTEVECTOR || args[1].tag != T_INT) cvm_abort("bytevector-u8-ref: expected (bytevector index)");
  int idx = (int)args[1].as.i;
  if (idx < 0 || idx >= args[0].as.bv->len) cvm_abort("bytevector-u8-ref: index %d out of range", idx);
  return v_int(args[0].as.bv->bytes[idx]);
}

static Value bi_bytevector_u8_set(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 3 || args[0].tag != T_BYTEVECTOR || args[1].tag != T_INT || args[2].tag != T_INT) cvm_abort("bytevector-u8-set!: expected (bytevector index byte)");
  int idx = (int)args[1].as.i;
  if (idx < 0 || idx >= args[0].as.bv->len) cvm_abort("bytevector-u8-set!: index %d out of range", idx);
  if (args[2].as.i < 0 || args[2].as.i > 255) cvm_abort("bytevector-u8-set!: byte out of range");
  args[0].as.bv->bytes[idx] = (unsigned char)args[2].as.i;
  return v_nil();
}
static Value bi_char_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("char?: expected an argument"); return v_bool(args[0].tag == T_CHAR); }
/* Mirrors the real interpreter's own procedure? exactly (predicates.cr):
 * deliberately narrow -- Builtin/BytecodeClosure/BytecodeCaseClosure
 * (T_RECORD_CALLABLE counts because RecordAccessor/RecordMutator/ctor/
 * pred are real Builtin SUBCLASSES there), but NOT SchemeParameter
 * (T_PARAMETER) -- a parameter is callable via apply's generic dispatch
 * without being procedure?-true. */
static Value bi_procedure_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("procedure?: expected an argument"); return v_bool(args[0].tag == T_CLOSURE || args[0].tag == T_CASE_CLOSURE || args[0].tag == T_RECORD_CALLABLE || args[0].tag == T_BUILTIN); }
static Value bi_number_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("number?: expected an argument"); return v_bool(args[0].tag == T_INT || args[0].tag == T_FLOAT); }
static Value bi_real_p(VM *vm, Value *args, int nargs) { return bi_number_p(vm, args, nargs); } /* no complex tower */
static Value bi_complex_p(VM *vm, Value *args, int nargs) { return bi_number_p(vm, args, nargs); } /* every number cvm has IS real, and every real is complex -- no genuinely-complex-but-not-real value exists here */
static Value bi_integer_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("integer?: expected an argument");
  if (args[0].tag == T_INT) return v_bool(1);
  if (args[0].tag == T_FLOAT) return v_bool(args[0].as.f == floor(args[0].as.f));
  return v_bool(0);
}
static Value bi_exact_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("exact?: expected an argument"); return v_bool(args[0].tag == T_INT); }
static Value bi_inexact_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("inexact?: expected an argument"); return v_bool(args[0].tag == T_FLOAT); }
static Value bi_exact_integer_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("exact-integer?: expected an argument"); return v_bool(args[0].tag == T_INT); }
static Value bi_eq_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 2) cvm_abort("eq?: expected two arguments"); return v_bool(cvm_eqv(args[0], args[1])); }
static Value bi_eqv_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 2) cvm_abort("eqv?: expected two arguments"); return v_bool(cvm_eqv(args[0], args[1])); }
static Value bi_equal_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 2) cvm_abort("equal?: expected two arguments"); return v_bool(cvm_equal(args[0], args[1])); }

/* ---- numeric predicates / conversions ---- */
static Value bi_zero_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("zero?: expected an argument");
  if (args[0].tag == T_INT) return v_bool(args[0].as.i == 0);
  if (args[0].tag == T_FLOAT) return v_bool(args[0].as.f == 0.0);
  cvm_abort("zero?: not a number");
}
static Value bi_positive_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("positive?: expected an argument");
  if (args[0].tag == T_INT) return v_bool(args[0].as.i > 0);
  if (args[0].tag == T_FLOAT) return v_bool(args[0].as.f > 0.0);
  cvm_abort("positive?: not a number");
}
static Value bi_negative_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("negative?: expected an argument");
  if (args[0].tag == T_INT) return v_bool(args[0].as.i < 0);
  if (args[0].tag == T_FLOAT) return v_bool(args[0].as.f < 0.0);
  cvm_abort("negative?: not a number");
}
static Value bi_odd_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1 || args[0].tag != T_INT) cvm_abort("odd?: expected an integer"); return v_bool(args[0].as.i % 2 != 0); }
static Value bi_even_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1 || args[0].tag != T_INT) cvm_abort("even?: expected an integer"); return v_bool(args[0].as.i % 2 == 0); }
static Value bi_abs(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("abs: expected an argument");
  if (args[0].tag == T_INT) return v_int(args[0].as.i < 0 ? -args[0].as.i : args[0].as.i);
  if (args[0].tag == T_FLOAT) return v_float(fabs(args[0].as.f));
  cvm_abort("abs: not a number");
}
static Value bi_min(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("min: expected at least one argument");
  Value m = args[0];
  for (int i = 1; i < nargs; i++) if (num_lt(args[i], m)) m = args[i];
  return m;
}
static Value bi_max(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("max: expected at least one argument");
  Value m = args[0];
  for (int i = 1; i < nargs; i++) if (num_gt(args[i], m)) m = args[i];
  return m;
}
static Value bi_round(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("round: expected an argument");
  if (args[0].tag == T_INT) return args[0];
  if (args[0].tag == T_FLOAT) return v_float(round(args[0].as.f));
  cvm_abort("round: not a number");
}
static Value bi_floor(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("floor: expected an argument");
  if (args[0].tag == T_INT) return args[0];
  if (args[0].tag == T_FLOAT) return v_float(floor(args[0].as.f));
  cvm_abort("floor: not a number");
}
static Value bi_ceiling(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("ceiling: expected an argument");
  if (args[0].tag == T_INT) return args[0];
  if (args[0].tag == T_FLOAT) return v_float(ceil(args[0].as.f));
  cvm_abort("ceiling: not a number");
}
static Value bi_truncate(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("truncate: expected an argument");
  if (args[0].tag == T_INT) return args[0];
  if (args[0].tag == T_FLOAT) return v_float(trunc(args[0].as.f));
  cvm_abort("truncate: not a number");
}
static Value bi_exact(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("exact: expected an argument");
  if (args[0].tag == T_INT) return args[0];
  if (args[0].tag == T_FLOAT) return v_int((int64_t)args[0].as.f);
  cvm_abort("exact: not a number");
}
static Value bi_inexact(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("inexact: expected an argument");
  if (args[0].tag == T_FLOAT) return args[0];
  if (args[0].tag == T_INT) return v_float((double)args[0].as.i);
  cvm_abort("inexact: not a number");
}

/* ---- pairs / lists ---- */
static Value bi_car(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1 || args[0].tag != T_PAIR) cvm_abort("car: expected a pair"); return args[0].as.pair->car; }
static Value bi_cdr(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1 || args[0].tag != T_PAIR) cvm_abort("cdr: expected a pair"); return args[0].as.pair->cdr; }

/* (scheme cxr)'s full caar..cddddr family, as REAL global procedures --
 * cvm already handles a car/cdr/cadr/etc. CALL SITE via the fused Cxr op
 * (a program the real analyzer compiles never needs these as ordinary
 * globals), but the self-hosted compiler does no such fusion, so anything
 * it compiles (e.g. `(scheme cxr)`'s own re-export, or a REPL/compiler-
 * mode target script using cadr directly) needs these to genuinely exist.
 * `ops` is read left-to-right exactly as it appears between the `c`/`r`
 * in the Scheme name (e.g. cadr's ops is "ad"); applied right-to-left
 * (innermost/last-in-the-string first), matching R7RS's own nesting
 * (cadr = (car (cdr x))). */
static Value cxr_apply(const char *ops, int n, Value v) {
  for (int i = n - 1; i >= 0; i--) {
    if (v.tag != T_PAIR) cvm_abort("c%.*sr: expected a pair", n, ops);
    v = (ops[i] == 'a') ? v.as.pair->car : v.as.pair->cdr;
  }
  return v;
}

#define DEFINE_CXR(name, opstr)                                                     \
  static Value bi_##name(VM *vm, Value *args, int nargs) {                          \
    (void)vm;                                                                       \
    if (nargs != 1) cvm_abort(#name ": expected 1 argument");                       \
    return cxr_apply(opstr, (int)(sizeof(opstr) - 1), args[0]);                     \
  }

DEFINE_CXR(caar, "aa")
DEFINE_CXR(cadr, "ad")
DEFINE_CXR(cdar, "da")
DEFINE_CXR(cddr, "dd")
DEFINE_CXR(caaar, "aaa")
DEFINE_CXR(caadr, "aad")
DEFINE_CXR(cadar, "ada")
DEFINE_CXR(caddr, "add")
DEFINE_CXR(cdaar, "daa")
DEFINE_CXR(cdadr, "dad")
DEFINE_CXR(cddar, "dda")
DEFINE_CXR(cdddr, "ddd")
DEFINE_CXR(caaaar, "aaaa")
DEFINE_CXR(caaadr, "aaad")
DEFINE_CXR(caadar, "aada")
DEFINE_CXR(caaddr, "aadd")
DEFINE_CXR(cadaar, "adaa")
DEFINE_CXR(cadadr, "adad")
DEFINE_CXR(caddar, "adda")
DEFINE_CXR(cadddr, "addd")
DEFINE_CXR(cdaaar, "daaa")
DEFINE_CXR(cdaadr, "daad")
DEFINE_CXR(cdadar, "dada")
DEFINE_CXR(cdaddr, "dadd")
DEFINE_CXR(cddaar, "ddaa")
DEFINE_CXR(cddadr, "ddad")
DEFINE_CXR(cdddar, "ddda")
DEFINE_CXR(cddddr, "dddd")
static Value bi_cons(VM *vm, Value *args, int nargs) { if (nargs < 2) cvm_abort("cons: expected two arguments"); return cvm_cons(vm, args[0], args[1]); }
static Value bi_list(VM *vm, Value *args, int nargs) {
  Value r = v_nil();
  for (int i = nargs - 1; i >= 0; i--) r = cvm_cons(vm, args[i], r);
  return r;
}
static Value bi_cons_star(VM *vm, Value *args, int nargs) {
  if (nargs == 0) return v_nil();
  Value r = args[nargs - 1];
  for (int i = nargs - 2; i >= 0; i--) r = cvm_cons(vm, args[i], r);
  return r;
}
static Value bi_append(VM *vm, Value *args, int nargs) {
  if (nargs == 0) return v_nil();
  Value result = args[nargs - 1];
  for (int i = nargs - 2; i >= 0; i--) {
    int n = 0;
    Value c = args[i];
    while (c.tag == T_PAIR) { n++; c = c.as.pair->cdr; }
    Value *tmp = malloc(sizeof(Value) * (size_t)(n ? n : 1));
    c = args[i];
    int idx = 0;
    while (c.tag == T_PAIR) { tmp[idx++] = c.as.pair->car; c = c.as.pair->cdr; }
    for (int j = n - 1; j >= 0; j--) result = cvm_cons(vm, tmp[j], result);
    free(tmp);
  }
  return result;
}
static Value bi_list_tail(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2 || args[1].tag != T_INT) cvm_abort("list-tail: expected (list k)");
  Value cur = args[0];
  for (int64_t k = args[1].as.i; k > 0; k--) {
    if (cur.tag != T_PAIR) cvm_abort("list-tail: index out of range");
    cur = cur.as.pair->cdr;
  }
  return cur;
}
static Value bi_list_ref(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2 || args[1].tag != T_INT) cvm_abort("list-ref: expected (list k)");
  Value cur = args[0];
  for (int64_t k = args[1].as.i; k > 0; k--) {
    if (cur.tag != T_PAIR) cvm_abort("list-ref: index out of range");
    cur = cur.as.pair->cdr;
  }
  if (cur.tag != T_PAIR) cvm_abort("list-ref: index out of range");
  return cur.as.pair->car;
}
static Value bi_last_pair(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_PAIR) cvm_abort("last-pair: expected a non-empty list");
  Value cur = args[0];
  while (cur.as.pair->cdr.tag == T_PAIR) cur = cur.as.pair->cdr;
  return cur;
}
static Value bi_assoc(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2) cvm_abort("assoc: expected (key alist)");
  Value cur = args[1];
  while (cur.tag == T_PAIR) {
    Value entry = cur.as.pair->car;
    if (entry.tag == T_PAIR && cvm_equal(entry.as.pair->car, args[0])) return entry;
    cur = cur.as.pair->cdr;
  }
  return v_bool(0);
}
static Value bi_assq(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2) cvm_abort("assq: expected (key alist)");
  Value cur = args[1];
  while (cur.tag == T_PAIR) {
    Value entry = cur.as.pair->car;
    if (entry.tag == T_PAIR && cvm_eqv(entry.as.pair->car, args[0])) return entry;
    cur = cur.as.pair->cdr;
  }
  return v_bool(0);
}
static Value bi_member(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2) cvm_abort("member: expected (key list)");
  Value cur = args[1];
  while (cur.tag == T_PAIR) {
    if (cvm_equal(cur.as.pair->car, args[0])) return cur;
    cur = cur.as.pair->cdr;
  }
  return v_bool(0);
}
static Value bi_memq(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2) cvm_abort("memq: expected (key list)");
  Value cur = args[1];
  while (cur.tag == T_PAIR) {
    if (cvm_eqv(cur.as.pair->car, args[0])) return cur;
    cur = cur.as.pair->cdr;
  }
  return v_bool(0);
}

/* ---- higher-order procedures (cvm_apply, vm.c, is the reentrant "call a
 * Scheme value from C" helper these all need). ---- */
static Value bi_apply(VM *vm, Value *args, int nargs) {
  if (nargs < 2) cvm_abort("apply: expected at least (proc ... list)");
  int n_extra = nargs - 2;
  Value list_arg = args[nargs - 1];
  int n_list = 0;
  Value c = list_arg;
  while (c.tag == T_PAIR) { n_list++; c = c.as.pair->cdr; }
  int total = n_extra + n_list;
  Value *call_args = malloc(sizeof(Value) * (size_t)(total ? total : 1));
  for (int i = 0; i < n_extra; i++) call_args[i] = args[1 + i];
  c = list_arg;
  int idx = n_extra;
  while (c.tag == T_PAIR) { call_args[idx++] = c.as.pair->car; c = c.as.pair->cdr; }
  Value result = cvm_apply(vm, args[0], call_args, total);
  free(call_args);
  return result;
}
static Value bi_map(VM *vm, Value *args, int nargs) {
  if (nargs < 2) cvm_abort("map: expected a procedure and at least one list");
  int n_lists = nargs - 1;
  Value *cursors = malloc(sizeof(Value) * (size_t)n_lists);
  Value *items = malloc(sizeof(Value) * (size_t)n_lists);
  for (int i = 0; i < n_lists; i++) cursors[i] = args[1 + i];
  Value *acc = NULL;
  int acc_len = 0, acc_cap = 0;
  for (;;) {
    int done = 0;
    for (int i = 0; i < n_lists; i++) if (cursors[i].tag != T_PAIR) { done = 1; break; }
    if (done) break;
    for (int i = 0; i < n_lists; i++) { items[i] = cursors[i].as.pair->car; cursors[i] = cursors[i].as.pair->cdr; }
    /* r is a genuinely new value (map's whole point) with no other
     * reference until it's consed into `result` below -- acc must be
     * GC-visible so a later cvm_apply's own allocations can't collect an
     * earlier iteration's result out from under this loop. */
    Value r = cvm_apply(vm, args[0], items, n_lists);
    if (acc_len >= acc_cap) { acc_cap = acc_cap ? acc_cap * 2 : 8; acc = GC_REALLOC(acc, sizeof(Value) * (size_t)acc_cap); }
    acc[acc_len++] = r;
  }
  Value result = v_nil();
  for (int i = acc_len - 1; i >= 0; i--) result = cvm_cons(vm, acc[i], result);
  free(cursors);
  free(items);
  return result;
}
static Value bi_for_each(VM *vm, Value *args, int nargs) {
  if (nargs < 2) cvm_abort("for-each: expected a procedure and at least one list");
  int n_lists = nargs - 1;
  Value *cursors = malloc(sizeof(Value) * (size_t)n_lists);
  Value *items = malloc(sizeof(Value) * (size_t)n_lists);
  for (int i = 0; i < n_lists; i++) cursors[i] = args[1 + i];
  for (;;) {
    int done = 0;
    for (int i = 0; i < n_lists; i++) if (cursors[i].tag != T_PAIR) { done = 1; break; }
    if (done) break;
    for (int i = 0; i < n_lists; i++) { items[i] = cursors[i].as.pair->car; cursors[i] = cursors[i].as.pair->cdr; }
    cvm_apply(vm, args[0], items, n_lists);
  }
  free(cursors);
  free(items);
  return v_nil();
}
static Value bi_string_for_each(VM *vm, Value *args, int nargs) {
  if (nargs < 2) cvm_abort("string-for-each: expected a procedure and at least one string");
  int n_strs = nargs - 1;
  int minlen = -1;
  for (int i = 0; i < n_strs; i++) {
    if (args[1 + i].tag != T_STR) cvm_abort("string-for-each: expected a string");
    int len = args[1 + i].as.str.len;
    if (minlen < 0 || len < minlen) minlen = len;
  }
  Value *chars = malloc(sizeof(Value) * (size_t)n_strs);
  for (int idx = 0; idx < minlen; idx++) {
    for (int i = 0; i < n_strs; i++) chars[i] = v_char((unsigned char)args[1 + i].as.str.chars[idx]);
    cvm_apply(vm, args[0], chars, n_strs);
  }
  free(chars);
  return v_nil();
}
static Value bi_filter(VM *vm, Value *args, int nargs) {
  if (nargs < 2) cvm_abort("filter: expected (pred list)");
  Value *acc = NULL;
  int len = 0, cap = 0;
  Value cur = args[1];
  while (cur.tag == T_PAIR) {
    Value item = cur.as.pair->car;
    Value keep = cvm_apply(vm, args[0], &item, 1);
    if (!v_falsy(keep)) {
      if (len >= cap) { cap = cap ? cap * 2 : 8; acc = realloc(acc, sizeof(Value) * (size_t)cap); }
      acc[len++] = item;
    }
    cur = cur.as.pair->cdr;
  }
  Value result = v_nil();
  for (int i = len - 1; i >= 0; i--) result = cvm_cons(vm, acc[i], result);
  free(acc);
  return result;
}

/* Simplified: this prototype has no multi-value Value representation, only
 * the common single-value-passthrough shape (call-with-values immediately
 * destructuring one value) — genuine (values a b ...) with other than
 * exactly one value isn't representable here. */
/* A single value is returned as itself, never wrapped in a T_VALUES
 * carrier — mirrors the real interpreter's own single-value convention
 * (see Op::Destructure's doc comment), so `(+ 1 (values 2))` and similar
 * single-value uses of `values` need no special handling anywhere else. */
static Value bi_values(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs == 1) return args[0];
  MultiValues *mv = GC_MALLOC(sizeof(MultiValues));
  mv->len = nargs;
  mv->items = GC_MALLOC(sizeof(Value) * (size_t)(nargs ? nargs : 1));
  for (int i = 0; i < nargs; i++) mv->items[i] = args[i];
  return v_values(mv);
}
static Value bi_call_with_values(VM *vm, Value *args, int nargs) {
  if (nargs < 2) cvm_abort("call-with-values: expected (producer consumer)");
  Value produced = cvm_apply(vm, args[0], NULL, 0);
  if (produced.tag == T_VALUES) {
    return cvm_apply(vm, args[1], produced.as.values->items, produced.as.values->len);
  }
  return cvm_apply(vm, args[1], &produced, 1);
}

/* ---- strings ---- */
static Value bi_string_append(VM *vm, Value *args, int nargs) {
  (void)vm;
  size_t total = 0;
  for (int i = 0; i < nargs; i++) {
    if (args[i].tag != T_STR) cvm_abort("string-append: expected a string");
    total += (size_t)args[i].as.str.len;
  }
  char *buf = GC_MALLOC(total ? total : 1);
  size_t off = 0;
  for (int i = 0; i < nargs; i++) {
    memcpy(buf + off, args[i].as.str.chars, (size_t)args[i].as.str.len);
    off += (size_t)args[i].as.str.len;
  }
  return v_str(buf, (int)total);
}
/* Copies `len` bytes starting at `chars` into a fresh, independently owned
 * buffer — used everywhere a "new string" is conceptually supposed to be
 * independent of whatever it was derived from (substring, symbol<->string
 * conversion), now that T_STR is mutable via string-set!: aliasing the
 * source's buffer directly (as this prototype used to do) would let a
 * later mutation of one silently corrupt the other. */
static char *copy_bytes(const char *chars, int len) {
  char *buf = GC_MALLOC((size_t)(len ? len : 1));
  if (len > 0) memcpy(buf, chars, (size_t)len);
  return buf;
}

static Value bi_substring(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2 || args[0].tag != T_STR || args[1].tag != T_INT) cvm_abort("substring: expected (string start [end])");
  int start = (int)args[1].as.i;
  int end = (nargs >= 3 && args[2].tag == T_INT) ? (int)args[2].as.i : args[0].as.str.len;
  if (start < 0 || end > args[0].as.str.len || start > end) cvm_abort("substring: index out of range");
  return v_str(copy_bytes(args[0].as.str.chars + start, end - start), end - start);
}

static Value bi_string_copy(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) cvm_abort("string-copy: expected a string");
  int start = (nargs >= 2 && args[1].tag == T_INT) ? (int)args[1].as.i : 0;
  int end = (nargs >= 3 && args[2].tag == T_INT) ? (int)args[2].as.i : args[0].as.str.len;
  if (start < 0 || end > args[0].as.str.len || start > end) cvm_abort("string-copy: index out of range");
  return v_str(copy_bytes(args[0].as.str.chars + start, end - start), end - start);
}
static Value bi_string_to_list(VM *vm, Value *args, int nargs) {
  if (nargs < 1 || args[0].tag != T_STR) cvm_abort("string->list: expected a string");
  Value r = v_nil();
  for (int i = args[0].as.str.len - 1; i >= 0; i--) r = cvm_cons(vm, v_char((unsigned char)args[0].as.str.chars[i]), r);
  return r;
}
static Value bi_list_to_string(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("list->string: expected a list of chars");
  int n = 0;
  Value c = args[0];
  while (c.tag == T_PAIR) { n++; c = c.as.pair->cdr; }
  char *buf = GC_MALLOC((size_t)(n ? n : 1));
  c = args[0];
  int i = 0;
  while (c.tag == T_PAIR) {
    if (c.as.pair->car.tag != T_CHAR) cvm_abort("list->string: expected a list of chars");
    buf[i++] = (char)c.as.pair->car.as.i;
    c = c.as.pair->cdr;
  }
  return v_str(buf, n);
}
static Value bi_make_string(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_INT) cvm_abort("make-string: expected a length");
  int64_t n = args[0].as.i;
  char fill = (nargs >= 2 && args[1].tag == T_CHAR) ? (char)args[1].as.i : ' ';
  char *buf = GC_MALLOC((size_t)(n ? n : 1));
  memset(buf, fill, (size_t)n);
  return v_str(buf, (int)n);
}
static Value bi_string_ctor(VM *vm, Value *args, int nargs) {
  (void)vm;
  char *buf = GC_MALLOC((size_t)(nargs ? nargs : 1));
  for (int i = 0; i < nargs; i++) {
    if (args[i].tag != T_CHAR) cvm_abort("string: expected chars");
    buf[i] = (char)args[i].as.i;
  }
  return v_str(buf, nargs);
}
static Value bi_string_eq(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2) cvm_abort("string=?: expected at least two strings");
  for (int i = 1; i < nargs; i++) {
    if (args[i - 1].tag != T_STR || args[i].tag != T_STR) cvm_abort("string=?: expected strings");
    if (args[i - 1].as.str.len != args[i].as.str.len ||
        memcmp(args[i - 1].as.str.chars, args[i].as.str.chars, (size_t)args[i].as.str.len) != 0) {
      return v_bool(0);
    }
  }
  return v_bool(1);
}
static Value bi_string_to_number(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) cvm_abort("string->number: expected a string");
  int len = args[0].as.str.len;
  char *buf = malloc((size_t)len + 1);
  memcpy(buf, args[0].as.str.chars, (size_t)len);
  buf[len] = 0;
  char *endptr;
  long long iv = strtoll(buf, &endptr, 10);
  if (endptr != buf && *endptr == 0) { free(buf); return v_int(iv); }
  double dv = strtod(buf, &endptr);
  if (endptr != buf && *endptr == 0) { free(buf); return v_float(dv); }
  free(buf);
  return v_bool(0);
}
static Value bi_number_to_string(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("number->string: expected a number");
  char buf[64];
  int len;
  if (args[0].tag == T_INT) {
    len = snprintf(buf, sizeof(buf), "%lld", (long long)args[0].as.i);
  } else if (args[0].tag == T_FLOAT) {
    double f = args[0].as.f;
    if (fabs(f) < 1e15 && f == (double)(int64_t)f) {
      len = snprintf(buf, sizeof(buf), "%lld.0", (long long)f);
    } else {
      len = snprintf(buf, sizeof(buf), "%.17g", f);
    }
  } else {
    cvm_abort("number->string: not a number");
  }
  char *copy = GC_MALLOC((size_t)len);
  memcpy(copy, buf, (size_t)len);
  return v_str(copy, len);
}
static Value bi_string_to_symbol(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1 || args[0].tag != T_STR) cvm_abort("string->symbol: expected a string"); return v_sym(copy_bytes(args[0].as.str.chars, args[0].as.str.len), args[0].as.str.len); }
static Value bi_symbol_to_string(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1 || args[0].tag != T_SYM) cvm_abort("symbol->string: expected a symbol"); return v_str(copy_bytes(args[0].as.str.chars, args[0].as.str.len), args[0].as.str.len); }
static Value bi_char_to_integer(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1 || args[0].tag != T_CHAR) cvm_abort("char->integer: expected a char"); return v_int(args[0].as.i); }
static Value bi_integer_to_char(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1 || args[0].tag != T_INT) cvm_abort("integer->char: expected an integer"); return v_char(args[0].as.i); }
static Value bi_char_eq(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2) cvm_abort("char=?: expected at least two chars");
  for (int i = 1; i < nargs; i++) {
    if (args[i - 1].tag != T_CHAR || args[i].tag != T_CHAR) cvm_abort("char=?: expected chars");
    if (args[i - 1].as.i != args[i].as.i) return v_bool(0);
  }
  return v_bool(1);
}

static Value bi_char_lt(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2) cvm_abort("char<?: expected at least two chars");
  for (int i = 1; i < nargs; i++) {
    if (args[i - 1].tag != T_CHAR || args[i].tag != T_CHAR) cvm_abort("char<?: expected chars");
    if (!(args[i - 1].as.i < args[i].as.i)) return v_bool(0);
  }
  return v_bool(1);
}

static Value bi_char_gt(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2) cvm_abort("char>?: expected at least two chars");
  for (int i = 1; i < nargs; i++) {
    if (args[i - 1].tag != T_CHAR || args[i].tag != T_CHAR) cvm_abort("char>?: expected chars");
    if (!(args[i - 1].as.i > args[i].as.i)) return v_bool(0);
  }
  return v_bool(1);
}

static Value bi_char_le(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2) cvm_abort("char<=?: expected at least two chars");
  for (int i = 1; i < nargs; i++) {
    if (args[i - 1].tag != T_CHAR || args[i].tag != T_CHAR) cvm_abort("char<=?: expected chars");
    if (!(args[i - 1].as.i <= args[i].as.i)) return v_bool(0);
  }
  return v_bool(1);
}

static Value bi_char_ge(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2) cvm_abort("char>=?: expected at least two chars");
  for (int i = 1; i < nargs; i++) {
    if (args[i - 1].tag != T_CHAR || args[i].tag != T_CHAR) cvm_abort("char>=?: expected chars");
    if (!(args[i - 1].as.i >= args[i].as.i)) return v_bool(0);
  }
  return v_bool(1);
}

/* ASCII-only (matches strings.c's own upcase/downcase scope, and cvm's
 * bytes-not-Unicode string-ref elsewhere) -- the self-hosted reader only
 * ever calls this on single-byte ASCII characters (radix/exactness prefix
 * letters, hex digits), so full Unicode case-folding isn't needed here. */
static Value bi_char_downcase(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 1 || args[0].tag != T_CHAR) cvm_abort("char-downcase: expected a char");
  int64_t c = args[0].as.i;
  if (c >= 'A' && c <= 'Z') c = c - 'A' + 'a';
  return v_char(c);
}

static Value bi_char_upcase(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 1 || args[0].tag != T_CHAR) cvm_abort("char-upcase: expected a char");
  int64_t c = args[0].as.i;
  if (c >= 'a' && c <= 'z') c = c - 'a' + 'A';
  return v_char(c);
}

/* ---- vectors ---- */
static Value bi_vector(VM *vm, Value *args, int nargs) {
  (void)vm;
  Vector *vec = GC_MALLOC(sizeof(Vector));
  vec->len = nargs;
  vec->items = GC_MALLOC(sizeof(Value) * (size_t)(nargs ? nargs : 1));
  for (int i = 0; i < nargs; i++) vec->items[i] = args[i];
  return v_vector(vec);
}
static Value bi_vector_to_list(VM *vm, Value *args, int nargs) {
  if (nargs < 1 || args[0].tag != T_VECTOR) cvm_abort("vector->list: expected a vector");
  Value r = v_nil();
  Vector *vec = args[0].as.vec;
  for (int i = vec->len - 1; i >= 0; i--) r = cvm_cons(vm, vec->items[i], r);
  return r;
}
static Value bi_list_to_vector(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("list->vector: expected a list");
  int n = 0;
  Value c = args[0];
  while (c.tag == T_PAIR) { n++; c = c.as.pair->cdr; }
  Vector *vec = GC_MALLOC(sizeof(Vector));
  vec->len = n;
  vec->items = GC_MALLOC(sizeof(Value) * (size_t)(n ? n : 1));
  c = args[0];
  int i = 0;
  while (c.tag == T_PAIR) { vec->items[i++] = c.as.pair->car; c = c.as.pair->cdr; }
  return v_vector(vec);
}

/* ---- misc ---- */
/* Builds a real condition (message + irritants list, not just a printed
 * string) so guard's error-object-message/error-object-irritants work
 * correctly on it -- unlike the old always-exits version, this raises to
 * the nearest guard handler if one is installed (see cvm_raise_condition/
 * Group G). */
static Value bi_error(VM *vm, Value *args, int nargs) {
  if (nargs < 1) cvm_abort("error: expected at least 1 argument");
  char *buf = NULL;
  size_t size = 0;
  FILE *ms = open_memstream(&buf, &size);
  print_value(ms, args[0]);
  for (int i = 1; i < nargs; i++) {
    fputc(' ', ms);
    print_value(ms, args[i]);
  }
  fclose(ms);

  Value irritants = v_nil();
  for (int i = nargs - 1; i >= 1; i--) irritants = cvm_cons(vm, args[i], irritants);
  Value cond = cvm_make_condition(vm, buf, size, irritants);
  free(buf);

  if (vm->n_handlers > 0) cvm_raise_condition(vm, cond);

  Value msg = cond.as.record->fields[0];
  fwrite(msg.as.str.chars, 1, (size_t)msg.as.str.len, stderr);
  fputc('\n', stderr);
  exit(1);
}

/* raise: signals `args[0]` AS-IS (no message/irritants wrapping -- unlike
 * `error`, the condition IS whatever value was passed, e.g. a bare
 * symbol), matching R7RS. */
static Value bi_raise(VM *vm, Value *args, int nargs) {
  if (nargs != 1) cvm_abort("raise: expected 1 argument");
  if (vm->n_handlers > 0) cvm_raise_condition(vm, args[0]);
  char *buf = NULL;
  size_t size = 0;
  FILE *ms = open_memstream(&buf, &size);
  fputs("uncaught exception: ", ms);
  print_value(ms, args[0]);
  fclose(ms);
  fwrite(buf, 1, size, stderr);
  fputc('\n', stderr);
  free(buf);
  exit(1);
}

static Value bi_error_object_p(VM *vm, Value *args, int nargs) {
  if (nargs < 1) cvm_abort("error-object?: expected an argument");
  return v_bool(cvm_is_condition(vm, args[0]));
}

static Value bi_error_object_message(VM *vm, Value *args, int nargs) {
  if (nargs < 1 || !cvm_is_condition(vm, args[0])) cvm_abort("error-object-message: expected an error object");
  return args[0].as.record->fields[0];
}

static Value bi_error_object_irritants(VM *vm, Value *args, int nargs) {
  if (nargs < 1 || !cvm_is_condition(vm, args[0])) cvm_abort("error-object-irritants: expected an error object");
  return args[0].as.record->fields[1];
}

static Value bi_make_parameter(VM *vm, Value *args, int nargs) {
  if (nargs < 1) cvm_abort("make-parameter: expected at least 1 argument");
  Parameter *p = GC_MALLOC(sizeof(Parameter));
  if (nargs >= 2) {
    p->has_converter = 1;
    p->converter = args[1];
    p->value = cvm_apply(vm, args[1], &args[0], 1);
  } else {
    p->has_converter = 0;
    p->converter = v_nil();
    p->value = args[0];
  }
  return v_parameter(p);
}
static Value bi_read_line(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)args;
  (void)nargs;
  char *line = NULL;
  size_t cap = 0;
  ssize_t n = getline(&line, &cap, stdin);
  if (n < 0) { free(line); return v_bool(0); /* eof-object placeholder */ }
  if (n > 0 && line[n - 1] == '\n') n--;
  char *copy = GC_MALLOC((size_t)(n ? n : 1));
  memcpy(copy, line, (size_t)n);
  free(line);
  return v_str(copy, (int)n);
}
/* (creme time)'s minimal surface surf.sld's logging middleware needs --
 * not worth its own module for two functions this small. */
static Value bi_current_time(VM *vm, Value *args, int nargs) {
  (void)vm; (void)args; (void)nargs;
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  return v_float((double)ts.tv_sec + (double)ts.tv_nsec / 1e9);
}
static Value bi_time_difference(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2) cvm_abort("time-difference: expected two times");
  double a = args[0].tag == T_FLOAT ? args[0].as.f : (double)args[0].as.i;
  double b = args[1].tag == T_FLOAT ? args[1].as.f : (double)args[1].as.i;
  return v_float(a - b);
}

/* (scheme process-context)'s minimal surface app.scm needs -- just enough
 * to read PORT, not a whole module for one function. */
static Value bi_get_environment_variable(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) cvm_abort("get-environment-variable: expected a string");
  char *name = malloc((size_t)args[0].as.str.len + 1);
  memcpy(name, args[0].as.str.chars, (size_t)args[0].as.str.len);
  name[args[0].as.str.len] = 0;
  const char *val = getenv(name);
  free(name);
  if (!val) return v_bool(0);
  int len = (int)strlen(val);
  char *copy = GC_MALLOC((size_t)(len ? len : 1));
  memcpy(copy, val, (size_t)len);
  return v_str(copy, len);
}

void cvm_register_builtins(VM *vm) {
  cvm_register_builtin(vm, "make-vector", bi_make_vector);
  cvm_register_builtin(vm, "current-second", bi_current_second);
  cvm_register_builtin(vm, "display", bi_display);
  cvm_register_builtin(vm, "newline", bi_newline);
  cvm_register_builtin(vm, "open-output-string", bi_open_output_string);
  cvm_register_builtin(vm, "get-output-string", bi_get_output_string);
  cvm_register_builtin(vm, "string-length", bi_string_length);
  cvm_register_builtin(vm, "write-string", bi_write_string);
  cvm_register_builtin(vm, "reverse", bi_reverse);
  cvm_register_builtin(vm, "length", bi_length);
  cvm_register_builtin(vm, "current-output-port", bi_current_output_port);

  cvm_register_builtin(vm, "not", bi_not);
  cvm_register_builtin(vm, "pair?", bi_pair_p);
  cvm_register_builtin(vm, "null?", bi_null_p);
  cvm_register_builtin(vm, "list?", bi_list_p);
  cvm_register_builtin(vm, "boolean?", bi_boolean_p);
  cvm_register_builtin(vm, "symbol?", bi_symbol_p);
  cvm_register_builtin(vm, "string?", bi_string_p);
  cvm_register_builtin(vm, "vector?", bi_vector_p);
  cvm_register_builtin(vm, "vector-ref", bi_vector_ref);
  cvm_register_builtin(vm, "vector-set!", bi_vector_set);
  cvm_register_builtin(vm, "vector-length", bi_vector_length);
  cvm_register_builtin(vm, "string-ref", bi_string_ref);
  cvm_register_builtin(vm, "string-set!", bi_string_set);
  cvm_register_builtin(vm, "bytevector-u8-ref", bi_bytevector_u8_ref);
  cvm_register_builtin(vm, "bytevector-u8-set!", bi_bytevector_u8_set);
  cvm_register_builtin(vm, "char?", bi_char_p);
  cvm_register_builtin(vm, "procedure?", bi_procedure_p);
  cvm_register_builtin(vm, "number?", bi_number_p);
  cvm_register_builtin(vm, "real?", bi_real_p);
  cvm_register_builtin(vm, "complex?", bi_complex_p);
  cvm_register_builtin(vm, "integer?", bi_integer_p);
  cvm_register_builtin(vm, "exact?", bi_exact_p);
  cvm_register_builtin(vm, "inexact?", bi_inexact_p);
  cvm_register_builtin(vm, "exact-integer?", bi_exact_integer_p);
  cvm_register_builtin(vm, "eq?", bi_eq_p);
  cvm_register_builtin(vm, "eqv?", bi_eqv_p);
  cvm_register_builtin(vm, "equal?", bi_equal_p);

  cvm_register_builtin(vm, "zero?", bi_zero_p);
  cvm_register_builtin(vm, "positive?", bi_positive_p);
  cvm_register_builtin(vm, "negative?", bi_negative_p);
  cvm_register_builtin(vm, "odd?", bi_odd_p);
  cvm_register_builtin(vm, "even?", bi_even_p);
  cvm_register_builtin(vm, "abs", bi_abs);
  cvm_register_builtin(vm, "min", bi_min);
  cvm_register_builtin(vm, "max", bi_max);
  cvm_register_builtin(vm, "round", bi_round);
  cvm_register_builtin(vm, "floor", bi_floor);
  cvm_register_builtin(vm, "ceiling", bi_ceiling);
  cvm_register_builtin(vm, "truncate", bi_truncate);
  cvm_register_builtin(vm, "exact", bi_exact);
  cvm_register_builtin(vm, "inexact", bi_inexact);
  cvm_register_builtin(vm, "exact->inexact", bi_inexact);
  cvm_register_builtin(vm, "inexact->exact", bi_exact);

  cvm_register_builtin(vm, "car", bi_car);
  cvm_register_builtin(vm, "cdr", bi_cdr);
  cvm_register_builtin(vm, "caar", bi_caar);
  cvm_register_builtin(vm, "cadr", bi_cadr);
  cvm_register_builtin(vm, "cdar", bi_cdar);
  cvm_register_builtin(vm, "cddr", bi_cddr);
  cvm_register_builtin(vm, "caaar", bi_caaar);
  cvm_register_builtin(vm, "caadr", bi_caadr);
  cvm_register_builtin(vm, "cadar", bi_cadar);
  cvm_register_builtin(vm, "caddr", bi_caddr);
  cvm_register_builtin(vm, "cdaar", bi_cdaar);
  cvm_register_builtin(vm, "cdadr", bi_cdadr);
  cvm_register_builtin(vm, "cddar", bi_cddar);
  cvm_register_builtin(vm, "cdddr", bi_cdddr);
  cvm_register_builtin(vm, "caaaar", bi_caaaar);
  cvm_register_builtin(vm, "caaadr", bi_caaadr);
  cvm_register_builtin(vm, "caadar", bi_caadar);
  cvm_register_builtin(vm, "caaddr", bi_caaddr);
  cvm_register_builtin(vm, "cadaar", bi_cadaar);
  cvm_register_builtin(vm, "cadadr", bi_cadadr);
  cvm_register_builtin(vm, "caddar", bi_caddar);
  cvm_register_builtin(vm, "cadddr", bi_cadddr);
  cvm_register_builtin(vm, "cdaaar", bi_cdaaar);
  cvm_register_builtin(vm, "cdaadr", bi_cdaadr);
  cvm_register_builtin(vm, "cdadar", bi_cdadar);
  cvm_register_builtin(vm, "cdaddr", bi_cdaddr);
  cvm_register_builtin(vm, "cddaar", bi_cddaar);
  cvm_register_builtin(vm, "cddadr", bi_cddadr);
  cvm_register_builtin(vm, "cdddar", bi_cdddar);
  cvm_register_builtin(vm, "cddddr", bi_cddddr);
  cvm_register_builtin(vm, "cons", bi_cons);
  cvm_register_builtin(vm, "list", bi_list);
  cvm_register_builtin(vm, "cons*", bi_cons_star);
  cvm_register_builtin(vm, "append", bi_append);
  cvm_register_builtin(vm, "list-tail", bi_list_tail);
  cvm_register_builtin(vm, "list-ref", bi_list_ref);
  cvm_register_builtin(vm, "last-pair", bi_last_pair);
  cvm_register_builtin(vm, "assoc", bi_assoc);
  cvm_register_builtin(vm, "assq", bi_assq);
  cvm_register_builtin(vm, "assv", bi_assq);
  cvm_register_builtin(vm, "member", bi_member);
  cvm_register_builtin(vm, "memq", bi_memq);
  cvm_register_builtin(vm, "memv", bi_memq);

  cvm_register_builtin(vm, "apply", bi_apply);
  cvm_register_builtin(vm, "map", bi_map);
  cvm_register_builtin(vm, "for-each", bi_for_each);
  cvm_register_builtin(vm, "string-for-each", bi_string_for_each);
  cvm_register_builtin(vm, "filter", bi_filter);
  cvm_register_builtin(vm, "values", bi_values);
  cvm_register_builtin(vm, "call-with-values", bi_call_with_values);

  cvm_register_builtin(vm, "string-append", bi_string_append);
  cvm_register_builtin(vm, "substring", bi_substring);
  cvm_register_builtin(vm, "string-copy", bi_string_copy);
  cvm_register_builtin(vm, "string->list", bi_string_to_list);
  cvm_register_builtin(vm, "list->string", bi_list_to_string);
  cvm_register_builtin(vm, "make-string", bi_make_string);
  cvm_register_builtin(vm, "string", bi_string_ctor);
  cvm_register_builtin(vm, "string=?", bi_string_eq);
  cvm_register_builtin(vm, "string->number", bi_string_to_number);
  cvm_register_builtin(vm, "number->string", bi_number_to_string);
  cvm_register_builtin(vm, "string->symbol", bi_string_to_symbol);
  cvm_register_builtin(vm, "symbol->string", bi_symbol_to_string);
  cvm_register_builtin(vm, "char->integer", bi_char_to_integer);
  cvm_register_builtin(vm, "integer->char", bi_integer_to_char);
  cvm_register_builtin(vm, "char=?", bi_char_eq);
  cvm_register_builtin(vm, "char<?", bi_char_lt);
  cvm_register_builtin(vm, "char>?", bi_char_gt);
  cvm_register_builtin(vm, "char<=?", bi_char_le);
  cvm_register_builtin(vm, "char>=?", bi_char_ge);
  cvm_register_builtin(vm, "char-downcase", bi_char_downcase);
  cvm_register_builtin(vm, "char-upcase", bi_char_upcase);

  cvm_register_builtin(vm, "vector", bi_vector);
  cvm_register_builtin(vm, "vector->list", bi_vector_to_list);
  cvm_register_builtin(vm, "list->vector", bi_list_to_vector);

  cvm_register_builtin(vm, "make-bytevector", bi_make_bytevector);
  cvm_register_builtin(vm, "bytevector", bi_bytevector);
  cvm_register_builtin(vm, "bytevector-length", bi_bytevector_length);
  cvm_register_builtin(vm, "bytevector?", bi_bytevector_p);

  cvm_register_builtin(vm, "force", bi_force);
  cvm_register_builtin(vm, "promise?", bi_promise_p);

  cvm_register_builtin(vm, "error", bi_error);
  cvm_register_builtin(vm, "raise", bi_raise);
  cvm_register_builtin(vm, "error-object?", bi_error_object_p);
  cvm_register_builtin(vm, "error-object-message", bi_error_object_message);
  cvm_register_builtin(vm, "error-object-irritants", bi_error_object_irritants);
  cvm_register_builtin(vm, "make-parameter", bi_make_parameter);
  cvm_register_builtin(vm, "quotient", bi_quotient);
  cvm_register_builtin(vm, "remainder", bi_remainder);
  cvm_register_builtin(vm, "modulo", bi_modulo);
  cvm_register_builtin(vm, "+", bi_plus);
  cvm_register_builtin(vm, "-", bi_minus);
  cvm_register_builtin(vm, "*", bi_star);
  cvm_register_builtin(vm, "/", bi_slash);
  cvm_register_builtin(vm, "<", bi_num_lt);
  cvm_register_builtin(vm, ">", bi_num_gt);
  cvm_register_builtin(vm, "<=", bi_num_le);
  cvm_register_builtin(vm, ">=", bi_num_ge);
  cvm_register_builtin(vm, "=", bi_num_eq);
  cvm_register_builtin(vm, "read-line", bi_read_line);
  cvm_register_builtin(vm, "current-time", bi_current_time);
  cvm_register_builtin(vm, "time-difference", bi_time_difference);
  cvm_register_builtin(vm, "get-environment-variable", bi_get_environment_variable);
}
