/* The builtins bench/creme.scm actually calls as plain (non-fused) global
 * procedures — see cvm/README.md's "builtins actually called" list. Nothing
 * else is registered; calling any other name aborts with "unbound
 * variable" (see vm.c's OP_GETGLOBAL and CallGlobal arms). */
#include <ctype.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

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

/* Resolves an optional (start [end]) byte range against `len`, mirroring
 * native's seq_range_args -- args[start_idx]/args[start_idx+1] if
 * present, defaulting to the full range otherwise. Shared by
 * bytevector-copy/read-bytevector!/write-bytevector below. */
static void byte_range_args(Value *args, int nargs, int start_idx, int len, int *first, int *last) {
  *first = (nargs > start_idx && args[start_idx].tag == T_INT) ? (int)args[start_idx].as.i : 0;
  *last = (nargs > start_idx + 1 && args[start_idx + 1].tag == T_INT) ? (int)args[start_idx + 1].as.i : len;
  if (*first < 0 || *last > len || *first > *last) cvm_abort("byte range out of bounds");
}

static Value bi_bytevector_copy(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_BYTEVECTOR) cvm_abort("bytevector-copy: expected a bytevector");
  Bytevector *src = args[0].as.bv;
  int first, last;
  byte_range_args(args, nargs, 1, src->len, &first, &last);
  Bytevector *bv = GC_MALLOC(sizeof(Bytevector));
  bv->len = last - first;
  bv->bytes = GC_MALLOC((size_t)(bv->len ? bv->len : 1));
  memcpy(bv->bytes, src->bytes + first, (size_t)bv->len);
  return v_bytevector(bv);
}

static Value bi_bytevector_copy_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 3 || args[0].tag != T_BYTEVECTOR || args[1].tag != T_INT || args[2].tag != T_BYTEVECTOR)
    cvm_abort("bytevector-copy!: expected (to at from [start [end]])");
  Bytevector *to = args[0].as.bv;
  int at = (int)args[1].as.i;
  Bytevector *from = args[2].as.bv;
  int first, last;
  byte_range_args(args, nargs, 3, from->len, &first, &last);
  int count = last - first;
  if (at < 0 || at + count > to->len) cvm_abort("bytevector-copy!: destination too small");
  memmove(to->bytes + at, from->bytes + first, (size_t)count);
  return v_nil();
}

static Value bi_bytevector_append(VM *vm, Value *args, int nargs) {
  (void)vm;
  int total = 0;
  for (int i = 0; i < nargs; i++) {
    if (args[i].tag != T_BYTEVECTOR) cvm_abort("bytevector-append: expected bytevectors");
    total += args[i].as.bv->len;
  }
  Bytevector *bv = GC_MALLOC(sizeof(Bytevector));
  bv->len = total;
  bv->bytes = GC_MALLOC((size_t)(total ? total : 1));
  int offset = 0;
  for (int i = 0; i < nargs; i++) {
    memcpy(bv->bytes + offset, args[i].as.bv->bytes, (size_t)args[i].as.bv->len);
    offset += args[i].as.bv->len;
  }
  return v_bytevector(bv);
}

/* Byte-for-byte reinterpretation, not real UTF-8 decoding/validation --
 * matches this prototype's byte-wide char/string scope elsewhere (see
 * bi_char_downcase's own "ASCII-only" comment); a genuinely invalid
 * UTF-8 byte sequence isn't rejected the way native's utf8->string does. */
static Value bi_utf8_to_string(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_BYTEVECTOR) cvm_abort("utf8->string: expected a bytevector");
  Bytevector *bv = args[0].as.bv;
  int first, last;
  byte_range_args(args, nargs, 1, bv->len, &first, &last);
  int len = last - first;
  char *copy = GC_MALLOC((size_t)(len ? len : 1));
  memcpy(copy, bv->bytes + first, (size_t)len);
  return v_str(copy, len);
}

static Value bi_string_to_utf8(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) cvm_abort("string->utf8: expected a string");
  int first, last;
  byte_range_args(args, nargs, 1, args[0].as.str.len, &first, &last);
  int len = last - first;
  Bytevector *bv = GC_MALLOC(sizeof(Bytevector));
  bv->len = len;
  bv->bytes = GC_MALLOC((size_t)(len ? len : 1));
  memcpy(bv->bytes, args[0].as.str.chars + first, (size_t)len);
  return v_bytevector(bv);
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

/* Exact/exact division produces a real, arbitrary-precision-reduced
 * T_RATIONAL now (see vm.c's num_div/make_rational_from_mpq) -- an
 * unevenly-divided int/int no longer silently falls back to a float the
 * way this prototype used to (before T_RATIONAL existed). Folds through
 * num_div exactly like bi_plus/bi_minus/bi_star already fold through
 * num_add/num_sub/num_mul. */
static Value bi_slash(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("/: expected at least 1 argument");
  if (nargs == 1) return num_div(v_int(1), args[0]);
  Value acc = args[0];
  for (int i = 1; i < nargs; i++) acc = num_div(acc, args[i]);
  return acc;
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

/* floor-quotient: floor(a/b) -- truncate-toward-zero quotient/remainder
 * (bi_quotient/bi_modulo above) adjusted down by one whenever the
 * remainder's sign doesn't match the divisor's, same correction
 * bi_modulo itself already applies to get a floor-toward-negative-
 * infinity remainder. floor-remainder is exactly modulo (registered as
 * a second name for the same function, matching how truncate-quotient/
 * truncate-remainder register quotient/remainder under R7RS's explicit
 * names below). */
static Value bi_floor_quotient(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 2 || args[0].tag != T_INT || args[1].tag != T_INT) cvm_abort("floor-quotient: expected two integers");
  int64_t a = args[0].as.i, b = args[1].as.i;
  if (b == 0) cvm_abort("floor-quotient: division by zero");
  int64_t q = a / b, r = a % b;
  if (r != 0 && ((r < 0) != (b < 0))) q -= 1;
  return v_int(q);
}

static Value make_values2(VM *vm, Value a, Value b) {
  (void)vm;
  MultiValues *mv = GC_MALLOC(sizeof(MultiValues));
  mv->len = 2;
  mv->items = GC_MALLOC(sizeof(Value) * 2);
  mv->items[0] = a;
  mv->items[1] = b;
  return v_values(mv);
}

/* (truncate/ a b)/(floor/ a b): the two-values forms of quotient+
 * remainder/floor-quotient+modulo -- mirrors native's own truncate_slash/
 * floor_slash exactly (each just bundles its own quotient/remainder
 * pair via `values`). */
static Value bi_truncate_slash(VM *vm, Value *args, int nargs) {
  return make_values2(vm, bi_quotient(vm, args, nargs), bi_remainder(vm, args, nargs));
}

static Value bi_floor_slash(VM *vm, Value *args, int nargs) {
  return make_values2(vm, bi_floor_quotient(vm, args, nargs), bi_modulo(vm, args, nargs));
}

static int64_t i64_gcd(int64_t a, int64_t b) {
  if (a < 0) a = -a;
  if (b < 0) b = -b;
  while (b != 0) {
    int64_t t = b;
    b = a % b;
    a = t;
  }
  return a;
}

static Value bi_gcd(VM *vm, Value *args, int nargs) {
  (void)vm;
  int64_t acc = 0;
  for (int i = 0; i < nargs; i++) {
    if (args[i].tag != T_INT) cvm_abort("gcd: expected an integer");
    acc = i64_gcd(acc, args[i].as.i);
  }
  return v_int(acc);
}

static Value bi_lcm(VM *vm, Value *args, int nargs) {
  (void)vm;
  int64_t acc = 1;
  for (int i = 0; i < nargs; i++) {
    if (args[i].tag != T_INT) cvm_abort("lcm: expected an integer");
    int64_t v = args[i].as.i < 0 ? -args[i].as.i : args[i].as.i;
    if (v == 0) { acc = 0; continue; }
    int64_t g = i64_gcd(acc, v);
    acc = (acc / g) * v;
  }
  return v_int(acc < 0 ? -acc : acc);
}

static int64_t i64_pow(int64_t base, int64_t exp) {
  int64_t result = 1;
  for (int64_t i = 0; i < exp; i++) result *= base;
  return result;
}

/* (expt base exp): an exact-integer base with a non-negative exact-
 * integer exponent stays an exact integer; a NEGATIVE exact-integer
 * exponent produces an exact T_RATIONAL (1/base^|exp|, sign folded into
 * the numerator since GMP's mpq_set_si takes an unsigned denominator) --
 * matches native's own expt exactly ((expt 2 -1) is exact 1/2, not
 * inexact 0.5). Everything else falls back to a float pow via as_double. */
static Value bi_expt(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 2) cvm_abort("expt: expected two arguments");
  Value base = args[0], ex = args[1];
  if (base.tag == T_INT && ex.tag == T_INT) {
    if (ex.as.i >= 0) return v_int(i64_pow(base.as.i, ex.as.i));
    int64_t denom = i64_pow(base.as.i, -ex.as.i);
    int64_t num = 1;
    if (denom < 0) { denom = -denom; num = -1; }
    mpq_t q;
    mpq_init(q);
    mpq_set_si(q, num, (unsigned long)denom);
    mpq_canonicalize(q);
    Value result = make_rational_from_mpq(q);
    mpq_clear(q);
    return result;
  }
  return v_float(pow(as_double(base, "expt"), as_double(ex, "expt")));
}

static Value bi_exact_integer_sqrt(VM *vm, Value *args, int nargs) {
  if (nargs < 1 || args[0].tag != T_INT || args[0].as.i < 0) cvm_abort("exact-integer-sqrt: expected a non-negative integer");
  int64_t n = args[0].as.i;
  int64_t root = (int64_t)sqrt((double)n);
  while (root > 0 && root * root > n) root--;
  while ((root + 1) * (root + 1) <= n) root++;
  int64_t rem = n - root * root;
  return make_values2(vm, v_int(root), v_int(rem));
}

/* R7RS's (scheme time) current-second: wall-clock time (seconds since the
 * epoch, fractional), usable for real dates/cross-process comparison --
 * NOT the same contract as current-jiffy below (elapsed monotonic time
 * since some arbitrary, per-process reference point). This used to read
 * CLOCK_MONOTONIC (a bug: monotonic time since an arbitrary boot-relative
 * point isn't a real date and isn't comparable across processes) -- fixed
 * to CLOCK_REALTIME, matching the native Crystal interpreter's own
 * current-second (Time.utc.to_unix_f). (creme bench)'s own use of
 * current-second (modules/creme/bench.sld) only ever takes a DIFFERENCE
 * of two calls, so this fix doesn't change its behavior at all. */
static Value bi_current_second(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)args;
  (void)nargs;
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  return v_float((double)ts.tv_sec + (double)ts.tv_nsec / 1e9);
}

/* (creme math)'s flonum->bits/bits->flonum -- an exact IEEE754 bit-level
 * reinterpret (not a numeric conversion), memcpy'd rather than a union/
 * pointer cast to stay strict-aliasing-safe. Needed by (creme bytecode)'s
 * own write-float64! (SCB1 chunk serialization), so ANY chunk containing
 * a float constant needs this -- not a test-specific gap, a foundational
 * one that surfaced the first time a spec/creme test file with a float
 * literal ran under cvm's compiler mode. */
static Value bi_flonum_to_bits(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_FLOAT) cvm_abort("flonum->bits: expected a float");
  int64_t bits;
  double f = args[0].as.f;
  memcpy(&bits, &f, sizeof(bits));
  return v_int(bits);
}
static Value bi_bits_to_flonum(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_INT) cvm_abort("bits->flonum: expected an exact integer");
  double f;
  int64_t bits = args[0].as.i;
  memcpy(&f, &bits, sizeof(f));
  return v_float(f);
}

/* ---- (scheme inexact)/(creme math): transcendentals -- thin libm
 * wrappers over as_double (already used by abs/magnitude/etc., accepts
 * T_INT/T_RATIONAL/T_FLOAT), same "always returns a float" contract as
 * native's own Math.sin/cos/etc.-based implementation. */
static Value bi_sin(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("sin: expected an argument"); return v_float(sin(as_double(args[0], "sin"))); }
static Value bi_cos(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("cos: expected an argument"); return v_float(cos(as_double(args[0], "cos"))); }
static Value bi_tan(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("tan: expected an argument"); return v_float(tan(as_double(args[0], "tan"))); }
static Value bi_asin(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("asin: expected an argument"); return v_float(asin(as_double(args[0], "asin"))); }
static Value bi_acos(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("acos: expected an argument"); return v_float(acos(as_double(args[0], "acos"))); }
static Value bi_atan(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("atan: expected an argument"); return v_float(atan(as_double(args[0], "atan"))); }
static Value bi_exp(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("exp: expected an argument"); return v_float(exp(as_double(args[0], "exp"))); }
static Value bi_log2(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("log2: expected an argument"); return v_float(log2(as_double(args[0], "log2"))); }
static Value bi_log10(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("log10: expected an argument"); return v_float(log10(as_double(args[0], "log10"))); }
static Value bi_atan2(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 2) cvm_abort("atan2: expected two arguments"); return v_float(atan2(as_double(args[0], "atan2"), as_double(args[1], "atan2"))); }
static Value bi_pow(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 2) cvm_abort("pow: expected two arguments"); return v_float(pow(as_double(args[0], "pow"), as_double(args[1], "pow"))); }
static Value bi_hypot(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 2) cvm_abort("hypot: expected two arguments"); return v_float(hypot(as_double(args[0], "hypot"), as_double(args[1], "hypot"))); }

/* log's optional 2nd argument is an explicit base, computed as log(x)/
 * log(base) -- matches native's own MathLibrary#log exactly. */
static Value bi_log(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("log: expected an argument");
  double x = log(as_double(args[0], "log"));
  return nargs >= 2 ? v_float(x / log(as_double(args[1], "log"))) : v_float(x);
}

/* (scheme inexact)'s sqrt/nan?/infinite?/finite? -- sqrt has an exact
 * perfect-square fast path ((sqrt 4) is exact 2, not inexact 2.0) ahead
 * of the float fallback, and returns a T_COMPLEX for a negative real
 * (the magnitude's square root goes on the imaginary axis, per R7RS),
 * mirroring native's own sqrt (modules/scheme/inexact.cr) exactly. A
 * genuinely T_COMPLEX argument aborts via as_double itself (same as
 * native's own Scheme.as_f64) -- this prototype's sqrt doesn't support
 * complex input either. */
static Value bi_sqrt(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("sqrt: expected an argument");
  Value v = args[0];
  if (v.tag == T_INT && v.as.i >= 0) {
    int64_t n = v.as.i;
    int64_t root = (int64_t)sqrt((double)n);
    while (root > 0 && root * root > n) root--;
    while ((root + 1) * (root + 1) <= n) root++;
    if (root * root == n) return v_int(root);
    return v_float(sqrt((double)n));
  }
  double d = as_double(v, "sqrt");
  if (d < 0) return make_complex(v_float(0.0), v_float(sqrt(-d)));
  return v_float(sqrt(d));
}

static Value bi_nan_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("nan?: expected an argument");
  return v_bool(args[0].tag == T_FLOAT && isnan(args[0].as.f));
}

static Value bi_infinite_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("infinite?: expected an argument");
  return v_bool(args[0].tag == T_FLOAT && isinf(args[0].as.f));
}

static Value bi_finite_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("finite?: expected an argument");
  return v_bool(args[0].tag != T_FLOAT || isfinite(args[0].as.f));
}

/* ---- (creme random): random-real/random-integer/random-seed!/
 * random-choice/random-shuffle. A splitmix64 PRNG (a single, process-
 * wide `rng_state`, not per-Interpreter the way native's own
 * interp.random_rng is) -- deliberately NOT bit-for-bit compatible with
 * Crystal's own Random (PCG-based), since nothing in this codebase
 * observes cvm's random sequence against a real Crystal process (see
 * spec/creme/random_spec.scm's own header comment on why its cases use
 * should-be-true?/range checks, or a seed-then-draw pair evaluated
 * wholly on ONE side at a time, rather than should-match-native? on a
 * bare draw -- two draws from the same live, unreset stream on
 * bootstrap-eval vs. native-eval would otherwise legitimately diverge). */
static uint64_t rng_state = 0x2545f4914f6cdd1dULL;

static uint64_t rng_next(void) {
  uint64_t z = (rng_state += 0x9e3779b97f4a7c15ULL);
  z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
  z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
  return z ^ (z >> 31);
}

static Value bi_random_real(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)args;
  (void)nargs;
  return v_float((double)(rng_next() >> 11) * (1.0 / 9007199254740992.0)); /* 2^53 */
}

static Value bi_random_integer(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_INT) cvm_abort("random-integer: expected an integer");
  int64_t n = args[0].as.i;
  if (n <= 0) cvm_abort("random-integer: n must be positive");
  return v_int((int64_t)(rng_next() % (uint64_t)n));
}

static Value bi_random_seed_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_INT) cvm_abort("random-seed!: expected an integer");
  rng_state = (uint64_t)args[0].as.i;
  return v_nil();
}

static Value bi_random_choice(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("random-choice: expects a list");
  int n = 0;
  Value cur = args[0];
  while (cur.tag == T_PAIR) { n++; cur = cur.as.pair->cdr; }
  if (n == 0) cvm_abort("random-choice: expects a non-empty list");
  int idx = (int)(rng_next() % (uint64_t)n);
  cur = args[0];
  for (int i = 0; i < idx; i++) cur = cur.as.pair->cdr;
  return cur.as.pair->car;
}

static Value bi_random_shuffle(VM *vm, Value *args, int nargs) {
  if (nargs < 1) cvm_abort("random-shuffle: expects a list");
  int n = 0;
  Value cur = args[0];
  while (cur.tag == T_PAIR) { n++; cur = cur.as.pair->cdr; }
  Value *arr = GC_MALLOC(sizeof(Value) * (size_t)(n ? n : 1));
  cur = args[0];
  for (int i = 0; i < n; i++) { arr[i] = cur.as.pair->car; cur = cur.as.pair->cdr; }
  /* Fisher-Yates */
  for (int i = n - 1; i > 0; i--) {
    int j = (int)(rng_next() % (uint64_t)(i + 1));
    Value tmp = arr[i];
    arr[i] = arr[j];
    arr[j] = tmp;
  }
  Value result = v_nil();
  for (int i = n - 1; i >= 0; i--) result = cvm_cons(vm, arr[i], result);
  return result;
}

/* Mirrors SchemeFloat#to_display (values.cr): whole floats print as "N.0",
 * everything else via a round-trip-safe %.17g — not byte-identical to
 * Crystal's shortest-round-trip formatter, but this bench only ever
 * displays timings, never string-compares them. */
/* `display` convention throughout (strings/chars print their raw content,
 * not a re-readable `write`-style quoted/escaped form) — `write` (below,
 * write_value) reuses this for every tag except strings/chars/pairs/
 * vectors/bytevectors, which it quotes itself. */
static void print_value(FILE *out, Value v) {
  switch (v.tag) {
  case T_INT:
    fprintf(out, "%lld", (long long)v.as.i);
    break;
  case T_FLOAT: {
    double f = v.as.f;
    /* R7RS's own external representation for these three, checked before
     * the whole-number/%.17g cases below -- C's own printf-family renders
     * them as bare "inf"/"-inf"/"nan" (via %.17g), not valid Scheme
     * syntax at all, which (creme compiler reader)'s self-compile test
     * surfaced: reader.sld's own inf-nan-literals table, re-serialized
     * through this printer as part of the self-hosting compile, came
     * back as the bare symbol `inf` -- "unbound variable: inf" the
     * first time that reconstituted text was ever re-read. */
    if (isnan(f)) { fputs("+nan.0", out); break; }
    if (isinf(f)) { fputs(f > 0 ? "+inf.0" : "-inf.0", out); break; }
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
    fputs(v.as.box.kind == BOX_KIND_EOF ? "#<eof>" : "#<native-object>", out);
    break;
  case T_RATIONAL:
    mpz_out_str(out, 10, mpq_numref(v.as.rational->q));
    fputc('/', out);
    mpz_out_str(out, 10, mpq_denref(v.as.rational->q));
    break;
  case T_COMPLEX: {
    /* Mirrors SchemeComplex#to_display/to_write exactly (complex.cr,
     * identical logic for both): always print the real part, then a
     * literal '+' UNLESS the imaginary part's own printed text starts
     * with '-' (naturally covers negative ints/rationals/floats and the
     * special "-inf.0"/"-nan.0" spellings), then the imaginary part,
     * then 'i'. NO elision -- a zero real part still prints (e.g.
     * "0-4i", never "-4i") and an imaginary coefficient of exactly 1
     * still prints its magnitude ("3+1i", never "3+i") -- this
     * deliberately matches native's own gap, not a nicer R7RS-idiomatic
     * form; see this project's reader_literals_spec.scm for confirming
     * cases. */
    print_value(out, v.as.cplx->real);
    char *buf = NULL;
    size_t size = 0;
    FILE *ms = open_memstream(&buf, &size);
    print_value(ms, v.as.cplx->imag);
    fclose(ms);
    if (size == 0 || buf[0] != '-') fputc('+', out);
    fwrite(buf, 1, size, out);
    free(buf);
    fputc('i', out);
    break;
  }
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
  p->kind = PORT_KIND_OUTPUT_STRING;
  return v_port(p);
}

static Value bi_get_output_string(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_PORT) cvm_abort("get-output-string: expected a port");
  Port *p = args[0].as.port;
  if (p->kind != PORT_KIND_OUTPUT_STRING) cvm_abort("get-output-string: expected a string output port");
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

/* Sentinel Ports identifying (current-output-port)/(current-input-port) --
 * write-string/display/write-char/write special-case the output one to
 * write straight to stdout rather than buffering (there's nothing to
 * later get-output-string out of "the real terminal"); read-char/peek-
 * char/read-line special-case the input one to read straight from stdin.
 * Both rely on `kind` being PORT_KIND_STDOUT/PORT_KIND_STDIN respectively
 * (PORT_KIND_STDOUT is enum value 0, so the zero-initialized static
 * struct already has the right kind; PORT_KIND_STDIN needs an explicit
 * initializer since it isn't the zero value). Neither is a genuine R7RS
 * parameter object (no (parameterize ((current-output-port ...)) ...)
 * support in this prototype) -- current-output-port/current-input-port
 * are plain 0-arg builtins that always return the same sentinel. */
static Port stdout_port_sentinel;
static Port stdin_port_sentinel = {.kind = PORT_KIND_STDIN};

static Value bi_current_output_port(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)args;
  (void)nargs;
  return v_port(&stdout_port_sentinel);
}

static Value bi_current_input_port(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)args;
  (void)nargs;
  return v_port(&stdin_port_sentinel);
}

static Value bi_write_string(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2 || args[0].tag != T_STR || args[1].tag != T_PORT) cvm_abort("write-string: expected (string port)");
  Port *p = args[1].as.port;
  if (p->kind == PORT_KIND_STDOUT || p->kind == PORT_KIND_OUTPUT_FILE) {
    fwrite(args[0].as.str.chars, 1, (size_t)args[0].as.str.len, p->kind == PORT_KIND_STDOUT ? stdout : p->file);
    return v_nil();
  }
  if (p->kind != PORT_KIND_OUTPUT_STRING) cvm_abort("write-string: expected an output port");
  port_buf_grow(p, args[0].as.str.len);
  memcpy(p->buf + p->len, args[0].as.str.chars, (size_t)args[0].as.str.len);
  p->len += args[0].as.str.len;
  return v_nil();
}

/* (write-char char [port]) -- port defaults to stdout, same convention
 * as write/write-string. Codepoints are stored/produced byte-wise in
 * this prototype (see string-ref's own comment), so a single byte
 * append/fputc mirrors that scope exactly. */
static Value bi_write_char(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_CHAR) cvm_abort("write-char: expected a char");
  if (nargs >= 2 && args[1].tag != T_PORT) cvm_abort("write-char: expected a port");
  Port *p = (nargs >= 2) ? args[1].as.port : &stdout_port_sentinel;
  char c = (char)args[0].as.i;
  if (p->kind == PORT_KIND_STDOUT || p->kind == PORT_KIND_OUTPUT_FILE) {
    fputc((int)(unsigned char)c, p->kind == PORT_KIND_STDOUT ? stdout : p->file);
    return v_nil();
  }
  if (p->kind != PORT_KIND_OUTPUT_STRING) cvm_abort("write-char: expected an output port");
  port_buf_grow(p, 1);
  p->buf[p->len] = c;
  p->len += 1;
  return v_nil();
}

/* ---- input ports: open-input-string, read-char/peek-char/read-line,
 * eof-object[?], port?/input-port?/output-port?, close-port. File ports
 * (open-input-file/open-output-file/call-with-*-file/file-exists?) reuse
 * this same kind-tagged Port -- see the "file ports" section below. */

static Value bi_open_input_string(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) cvm_abort("open-input-string: expected a string");
  Port *p = GC_MALLOC(sizeof(Port));
  p->kind = PORT_KIND_INPUT_STRING;
  p->len = args[0].as.str.len;
  p->buf = GC_MALLOC((size_t)(p->len ? p->len : 1));
  memcpy(p->buf, args[0].as.str.chars, (size_t)p->len);
  p->pos = 0;
  return v_port(p);
}

static Value bi_port_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("port?: expected an argument");
  return v_bool(args[0].tag == T_PORT);
}

static int port_is_input(Port *p) { return p->kind == PORT_KIND_INPUT_STRING || p->kind == PORT_KIND_STDIN || p->kind == PORT_KIND_INPUT_FILE; }
static int port_is_output(Port *p) { return p->kind == PORT_KIND_OUTPUT_STRING || p->kind == PORT_KIND_STDOUT || p->kind == PORT_KIND_OUTPUT_FILE; }

static Value bi_input_port_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("input-port?: expected an argument");
  return v_bool(args[0].tag == T_PORT && port_is_input(args[0].as.port));
}

static Value bi_output_port_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("output-port?: expected an argument");
  return v_bool(args[0].tag == T_PORT && port_is_output(args[0].as.port));
}

static Value bi_eof_object(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)args;
  (void)nargs;
  return v_box(NULL, BOX_KIND_EOF);
}

static Value bi_eof_object_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("eof-object?: expected an argument");
  return v_bool(args[0].tag == T_BOX && args[0].as.box.kind == BOX_KIND_EOF);
}

static Value bi_close_port(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_PORT) cvm_abort("close-port: expected a port");
  Port *p = args[0].as.port;
  if (!p->closed && (p->kind == PORT_KIND_INPUT_FILE || p->kind == PORT_KIND_OUTPUT_FILE) && p->file) fclose(p->file);
  p->closed = 1;
  return v_nil();
}

/* ---- file ports: open-input-file/open-output-file/call-with-input-file/
 * call-with-output-file/file-exists?. Builds directly on the kind-tagged
 * Port introduced above -- PORT_KIND_INPUT_FILE/PORT_KIND_OUTPUT_FILE use
 * Port's `file` field (an fopen'd FILE*) instead of buf/len/cap/pos, and
 * read-char/peek-char/read-line/write-string/write-char/write already
 * have a matching kind branch reading/writing through `file` (see each
 * function's own STDIN/STDOUT branch, extended alongside these). */
static char *value_str_to_cstr(Value s) {
  char *path = malloc((size_t)s.as.str.len + 1);
  memcpy(path, s.as.str.chars, (size_t)s.as.str.len);
  path[s.as.str.len] = '\0';
  return path;
}

static Value bi_file_exists_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) cvm_abort("file-exists?: expected a string");
  char *path = value_str_to_cstr(args[0]);
  int exists = access(path, F_OK) == 0;
  free(path);
  return v_bool(exists);
}

static Value bi_open_input_file(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) cvm_abort("open-input-file: expected a string");
  char *path = value_str_to_cstr(args[0]);
  FILE *f = fopen(path, "r");
  if (!f) cvm_abort("open-input-file: file not found: %s", path);
  free(path);
  Port *p = GC_MALLOC(sizeof(Port));
  p->kind = PORT_KIND_INPUT_FILE;
  p->file = f;
  return v_port(p);
}

static Value bi_open_output_file(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) cvm_abort("open-output-file: expected a string");
  char *path = value_str_to_cstr(args[0]);
  FILE *f = fopen(path, "w");
  if (!f) cvm_abort("open-output-file: could not open: %s", path);
  free(path);
  Port *p = GC_MALLOC(sizeof(Port));
  p->kind = PORT_KIND_OUTPUT_FILE;
  p->file = f;
  return v_port(p);
}

/* (call-with-input-file path proc)/(call-with-output-file path proc):
 * open, apply proc to the port, close -- unconditionally, even if proc
 * itself already closed it (bi_close_port/fclose are idempotent-safe
 * here since `closed` is checked first). */
static Value bi_call_with_input_file(VM *vm, Value *args, int nargs) {
  if (nargs < 2 || args[0].tag != T_STR) cvm_abort("call-with-input-file: expected (string proc)");
  Value port_val = bi_open_input_file(vm, args, 1);
  Value result = cvm_apply(vm, args[1], &port_val, 1);
  Port *p = port_val.as.port;
  if (!p->closed) fclose(p->file);
  p->closed = 1;
  return result;
}

static Value bi_call_with_output_file(VM *vm, Value *args, int nargs) {
  if (nargs < 2 || args[0].tag != T_STR) cvm_abort("call-with-output-file: expected (string proc)");
  Value port_val = bi_open_output_file(vm, args, 1);
  Value result = cvm_apply(vm, args[1], &port_val, 1);
  Port *p = port_val.as.port;
  if (!p->closed) fclose(p->file);
  p->closed = 1;
  return result;
}

/* Resolves the (optional, trailing) port argument for read-char/peek-char/
 * read-line -- defaults to current-input-port's stdin sentinel, mirroring
 * the native interpreter's own input_port_arg (base/io.cr). */
static Port *input_port_arg(Value *args, int nargs, int port_argidx, const char *who) {
  Port *p = (nargs > port_argidx) ? (args[port_argidx].tag == T_PORT ? args[port_argidx].as.port : NULL) : &stdin_port_sentinel;
  if (!p) cvm_abort("%s: expected a port", who);
  if (!port_is_input(p)) cvm_abort("%s: expected an input port", who);
  if (p->closed) cvm_abort("%s: port is closed", who);
  return p;
}

static Value bi_read_char(VM *vm, Value *args, int nargs) {
  (void)vm;
  Port *p = input_port_arg(args, nargs, 0, "read-char");
  if (p->kind == PORT_KIND_STDIN || p->kind == PORT_KIND_INPUT_FILE) {
    FILE *stream = p->kind == PORT_KIND_STDIN ? stdin : p->file;
    int c = fgetc(stream);
    return c == EOF ? bi_eof_object(vm, NULL, 0) : v_char(c);
  }
  if (p->pos >= p->len) return bi_eof_object(vm, NULL, 0);
  return v_char((unsigned char)p->buf[p->pos++]);
}

static Value bi_peek_char(VM *vm, Value *args, int nargs) {
  (void)vm;
  Port *p = input_port_arg(args, nargs, 0, "peek-char");
  if (p->kind == PORT_KIND_STDIN || p->kind == PORT_KIND_INPUT_FILE) {
    FILE *stream = p->kind == PORT_KIND_STDIN ? stdin : p->file;
    int c = fgetc(stream);
    if (c == EOF) return bi_eof_object(vm, NULL, 0);
    ungetc(c, stream);
    return v_char(c);
  }
  if (p->pos >= p->len) return bi_eof_object(vm, NULL, 0);
  return v_char((unsigned char)p->buf[p->pos]);
}

static Value bi_char_ready_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)args;
  (void)nargs;
  /* This prototype's ports are either an already-fully-buffered string
   * (always ready, or already at eof) or real blocking stdio (no
   * non-blocking peek available without extra plumbing) -- always
   * returning #t is R7RS-conformant (char-ready? may always return #t;
   * the guarantee it gives is only that #f means a read WOULD block). */
  return v_bool(1);
}

/* ---- bytevector ports: open-input-bytevector/open-output-bytevector/
 * get-output-bytevector, binary-port?/textual-port?, input-port-open?/
 * output-port-open?, read-u8/peek-u8/write-u8/read-bytevector[!]/
 * write-bytevector, call-with-port. Reuses PORT_KIND_INPUT_STRING/
 * PORT_KIND_OUTPUT_STRING's exact buf/len/cap/pos mechanics -- the only
 * difference from a textual string port is the `binary` flag (see its
 * own comment in value.h) and the Value tag these wrap bytes in
 * (T_INT/T_BYTEVECTOR here vs. read-char/peek-char/get-output-string's
 * T_CHAR/T_STR). */

static Value bi_open_input_bytevector(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_BYTEVECTOR) cvm_abort("open-input-bytevector: expected a bytevector");
  Bytevector *bv = args[0].as.bv;
  Port *p = GC_MALLOC(sizeof(Port));
  p->kind = PORT_KIND_INPUT_STRING;
  p->binary = 1;
  p->len = bv->len;
  p->buf = GC_MALLOC((size_t)(p->len ? p->len : 1));
  memcpy(p->buf, bv->bytes, (size_t)p->len);
  p->pos = 0;
  return v_port(p);
}

static Value bi_open_output_bytevector(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)args;
  (void)nargs;
  Port *p = GC_MALLOC(sizeof(Port));
  p->kind = PORT_KIND_OUTPUT_STRING;
  p->binary = 1;
  return v_port(p);
}

static Value bi_get_output_bytevector(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_PORT) cvm_abort("get-output-bytevector: expected a port");
  Port *p = args[0].as.port;
  if (p->kind != PORT_KIND_OUTPUT_STRING) cvm_abort("get-output-bytevector: expected a bytevector output port");
  Bytevector *bv = GC_MALLOC(sizeof(Bytevector));
  bv->len = p->len;
  bv->bytes = GC_MALLOC((size_t)(p->len ? p->len : 1));
  memcpy(bv->bytes, p->buf, (size_t)p->len);
  return v_bytevector(bv);
}

static Value bi_binary_port_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("binary-port?: expected an argument");
  return v_bool(args[0].tag == T_PORT && args[0].as.port->binary);
}

static Value bi_textual_port_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("textual-port?: expected an argument");
  return v_bool(args[0].tag == T_PORT && !args[0].as.port->binary);
}

static Value bi_input_port_open_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_PORT) cvm_abort("input-port-open?: expected a port");
  Port *p = args[0].as.port;
  return v_bool(port_is_input(p) && !p->closed);
}

static Value bi_output_port_open_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_PORT) cvm_abort("output-port-open?: expected a port");
  Port *p = args[0].as.port;
  return v_bool(port_is_output(p) && !p->closed);
}

static Value bi_read_u8(VM *vm, Value *args, int nargs) {
  (void)vm;
  Port *p = input_port_arg(args, nargs, 0, "read-u8");
  if (p->kind == PORT_KIND_STDIN || p->kind == PORT_KIND_INPUT_FILE) {
    FILE *stream = p->kind == PORT_KIND_STDIN ? stdin : p->file;
    int c = fgetc(stream);
    return c == EOF ? bi_eof_object(vm, NULL, 0) : v_int(c);
  }
  if (p->pos >= p->len) return bi_eof_object(vm, NULL, 0);
  return v_int((unsigned char)p->buf[p->pos++]);
}

static Value bi_peek_u8(VM *vm, Value *args, int nargs) {
  (void)vm;
  Port *p = input_port_arg(args, nargs, 0, "peek-u8");
  if (p->kind == PORT_KIND_STDIN || p->kind == PORT_KIND_INPUT_FILE) {
    FILE *stream = p->kind == PORT_KIND_STDIN ? stdin : p->file;
    int c = fgetc(stream);
    if (c == EOF) return bi_eof_object(vm, NULL, 0);
    ungetc(c, stream);
    return v_int(c);
  }
  if (p->pos >= p->len) return bi_eof_object(vm, NULL, 0);
  return v_int((unsigned char)p->buf[p->pos]);
}

/* u8-ready? shares char-ready?'s own "always #t" reasoning exactly (see
 * bi_char_ready_p's comment) -- registered as a second name for the same
 * function rather than duplicated below. */

static Value bi_write_u8(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_INT) cvm_abort("write-u8: expected a byte");
  if (nargs < 2 || args[1].tag != T_PORT) cvm_abort("write-u8: expects a port");
  Port *p = args[1].as.port;
  char c = (char)args[0].as.i;
  if (p->kind == PORT_KIND_STDOUT || p->kind == PORT_KIND_OUTPUT_FILE) {
    fputc((int)(unsigned char)c, p->kind == PORT_KIND_STDOUT ? stdout : p->file);
    return v_nil();
  }
  if (p->kind != PORT_KIND_OUTPUT_STRING) cvm_abort("write-u8: expected an output port");
  port_buf_grow(p, 1);
  p->buf[p->len] = c;
  p->len += 1;
  return v_nil();
}

static Value bi_read_bytevector(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_INT) cvm_abort("read-bytevector: expected a count");
  int n = (int)args[0].as.i;
  if (n < 0) cvm_abort("read-bytevector: count must be non-negative");
  Port *p = input_port_arg(args, nargs, 1, "read-bytevector");
  Bytevector *bv = GC_MALLOC(sizeof(Bytevector));
  bv->bytes = GC_MALLOC((size_t)(n ? n : 1));
  int read = 0;
  if (p->kind == PORT_KIND_STDIN || p->kind == PORT_KIND_INPUT_FILE) {
    FILE *stream = p->kind == PORT_KIND_STDIN ? stdin : p->file;
    read = (int)fread(bv->bytes, 1, (size_t)n, stream);
  } else {
    int avail = p->len - p->pos;
    read = (n < avail) ? n : avail;
    if (read < 0) read = 0;
    memcpy(bv->bytes, p->buf + p->pos, (size_t)read);
    p->pos += read;
  }
  if (read == 0 && n > 0) return bi_eof_object(vm, NULL, 0);
  bv->len = read;
  return v_bytevector(bv);
}

static Value bi_read_bytevector_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_BYTEVECTOR) cvm_abort("read-bytevector!: expected a bytevector");
  Bytevector *bv = args[0].as.bv;
  Port *p = input_port_arg(args, nargs, 1, "read-bytevector!");
  int first, last;
  byte_range_args(args, nargs, 2, bv->len, &first, &last);
  int want = last - first;
  int read = 0;
  if (p->kind == PORT_KIND_STDIN || p->kind == PORT_KIND_INPUT_FILE) {
    FILE *stream = p->kind == PORT_KIND_STDIN ? stdin : p->file;
    read = (int)fread(bv->bytes + first, 1, (size_t)want, stream);
  } else {
    int avail = p->len - p->pos;
    read = (want < avail) ? want : avail;
    if (read < 0) read = 0;
    memcpy(bv->bytes + first, p->buf + p->pos, (size_t)read);
    p->pos += read;
  }
  if (read == 0 && want > 0) return bi_eof_object(vm, NULL, 0);
  return v_int(read);
}

static Value bi_write_bytevector(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_BYTEVECTOR) cvm_abort("write-bytevector: expected a bytevector");
  if (nargs < 2 || args[1].tag != T_PORT) cvm_abort("write-bytevector: expects a port");
  Bytevector *bv = args[0].as.bv;
  Port *p = args[1].as.port;
  int first, last;
  byte_range_args(args, nargs, 2, bv->len, &first, &last);
  int len = last - first;
  if (p->kind == PORT_KIND_STDOUT || p->kind == PORT_KIND_OUTPUT_FILE) {
    fwrite(bv->bytes + first, 1, (size_t)len, p->kind == PORT_KIND_STDOUT ? stdout : p->file);
    return v_nil();
  }
  if (p->kind != PORT_KIND_OUTPUT_STRING) cvm_abort("write-bytevector: expected an output port");
  port_buf_grow(p, len);
  memcpy(p->buf + p->len, bv->bytes + first, (size_t)len);
  p->len += len;
  return v_nil();
}

/* (call-with-port port proc): applies proc to port, closing it afterward
 * regardless of how proc returns -- mirrors call-with-input-file/call-
 * with-output-file's own unconditional-close pattern above, just for an
 * already-open port instead of one this function opens itself. */
static Value bi_call_with_port(VM *vm, Value *args, int nargs) {
  if (nargs < 2 || args[0].tag != T_PORT) cvm_abort("call-with-port: expected (port proc)");
  Port *p = args[0].as.port;
  Value result = cvm_apply(vm, args[1], args, 1);
  if (!p->closed && (p->kind == PORT_KIND_INPUT_FILE || p->kind == PORT_KIND_OUTPUT_FILE) && p->file) fclose(p->file);
  p->closed = 1;
  return result;
}

/* Shared kind-dispatched Port write, exposed via vm.h (cvm_port_write_bytes)
 * for a module outside this file (csv.c's streaming writer) to reuse
 * without duplicating the STDOUT/OUTPUT_FILE/OUTPUT_STRING dispatch
 * bi_write_string/bi_write_char/bi_write already do inline. */
void cvm_port_write_bytes(Port *p, const char *bytes, int len) {
  if (p->kind == PORT_KIND_STDOUT || p->kind == PORT_KIND_OUTPUT_FILE) {
    fwrite(bytes, 1, (size_t)len, p->kind == PORT_KIND_STDOUT ? stdout : p->file);
    return;
  }
  if (p->kind != PORT_KIND_OUTPUT_STRING) cvm_abort("write: expected an output port");
  port_buf_grow(p, len);
  memcpy(p->buf + p->len, bytes, (size_t)len);
  p->len += len;
}

/* Shared kind-dispatched Port read, exposed via vm.h (cvm_port_read_char/
 * cvm_port_peek_char) for csv.c's streaming reader to reuse instead of
 * duplicating read-char/peek-char's own STDIN/INPUT_FILE/INPUT_STRING
 * dispatch. Returns -1 at EOF, else a byte 0-255 -- caller-side EOF
 * checks stay simple ints rather than round-tripping through the
 * BOX_KIND_EOF Value the Scheme-visible read-char/peek-char return. */
int cvm_port_read_char(Port *p) {
  if (p->kind == PORT_KIND_STDIN || p->kind == PORT_KIND_INPUT_FILE) {
    FILE *stream = p->kind == PORT_KIND_STDIN ? stdin : p->file;
    int c = fgetc(stream);
    return c == EOF ? -1 : c;
  }
  if (p->pos >= p->len) return -1;
  return (unsigned char)p->buf[p->pos++];
}

int cvm_port_peek_char(Port *p) {
  if (p->kind == PORT_KIND_STDIN || p->kind == PORT_KIND_INPUT_FILE) {
    FILE *stream = p->kind == PORT_KIND_STDIN ? stdin : p->file;
    int c = fgetc(stream);
    if (c == EOF) return -1;
    ungetc(c, stream);
    return c;
  }
  if (p->pos >= p->len) return -1;
  return (unsigned char)p->buf[p->pos];
}

static Value bi_read_line(VM *vm, Value *args, int nargs) {
  (void)vm;
  Port *p = input_port_arg(args, nargs, 0, "read-line");
  if (p->kind == PORT_KIND_STDIN || p->kind == PORT_KIND_INPUT_FILE) {
    FILE *stream = p->kind == PORT_KIND_STDIN ? stdin : p->file;
    char *line = NULL;
    size_t cap = 0;
    ssize_t got = getline(&line, &cap, stream);
    if (got < 0) { free(line); return bi_eof_object(vm, NULL, 0); }
    if (got > 0 && line[got - 1] == '\n') got--;
    char *copy = GC_MALLOC((size_t)(got ? got : 1));
    memcpy(copy, line, (size_t)got);
    free(line);
    return v_str(copy, (int)got);
  }
  if (p->pos >= p->len) return bi_eof_object(vm, NULL, 0);
  int start = p->pos;
  while (p->pos < p->len && p->buf[p->pos] != '\n') p->pos++;
  int line_len = p->pos - start;
  char *copy = GC_MALLOC((size_t)(line_len ? line_len : 1));
  memcpy(copy, p->buf + start, (size_t)line_len);
  if (p->pos < p->len) p->pos++; /* consume the newline itself */
  return v_str(copy, line_len);
}

/* (scheme write)'s `write`, absent from this prototype until now (see
 * print_value's own header comment on why only `display` existed) --
 * needed by (creme spec)/(creme compiler spec-helper)'s write-to-string,
 * used throughout the spec/creme test suite. Only strings/chars/pairs/vectors/
 * bytevectors need write's own quoted/re-readable form; every other tag
 * (numbers, symbols, booleans, nil, records, procedures, ...) prints
 * identically under write and display in this project's own scope, so
 * those fall through to print_value unchanged. */
static void write_string_literal(FILE *out, const char *chars, int len) {
  fputc('"', out);
  for (int i = 0; i < len; i++) {
    unsigned char c = (unsigned char)chars[i];
    switch (c) {
    case '"': fputs("\\\"", out); break;
    case '\\': fputs("\\\\", out); break;
    case '\n': fputs("\\n", out); break;
    case '\t': fputs("\\t", out); break;
    case '\r': fputs("\\r", out); break;
    default: fputc(c, out); break;
    }
  }
  fputc('"', out);
}

static void write_char_literal(FILE *out, int64_t codepoint) {
  fputs("#\\", out);
  switch (codepoint) {
  case ' ': fputs("space", out); break;
  case '\n': fputs("newline", out); break;
  case '\t': fputs("tab", out); break;
  case '\r': fputs("return", out); break;
  case 0: fputs("null", out); break;
  default: fputc((int)codepoint, out); break;
  }
}

static void write_value(FILE *out, Value v) {
  switch (v.tag) {
  case T_STR:
    write_string_literal(out, v.as.str.chars, v.as.str.len);
    break;
  case T_CHAR:
    write_char_literal(out, v.as.i);
    break;
  case T_PAIR: {
    fputc('(', out);
    Value cur = v;
    int first = 1;
    while (cur.tag == T_PAIR) {
      if (!first) fputc(' ', out);
      first = 0;
      write_value(out, cur.as.pair->car);
      cur = cur.as.pair->cdr;
    }
    if (cur.tag != T_NIL) {
      fputs(" . ", out);
      write_value(out, cur);
    }
    fputc(')', out);
    break;
  }
  case T_VECTOR: {
    fputs("#(", out);
    for (int i = 0; i < v.as.vec->len; i++) {
      if (i) fputc(' ', out);
      write_value(out, v.as.vec->items[i]);
    }
    fputc(')', out);
    break;
  }
  case T_BYTEVECTOR: {
    fputs("#u8(", out);
    for (int i = 0; i < v.as.bv->len; i++) {
      if (i) fputc(' ', out);
      fprintf(out, "%d", (int)v.as.bv->bytes[i]);
    }
    fputc(')', out);
    break;
  }
  default:
    print_value(out, v);
    break;
  }
}

/* (write obj [port]) -- port defaults to stdout, same convention
 * display/write-string already use. Renders through an in-memory stream
 * first (open_memstream, the same trick bi_error/bi_raise already use
 * below) so the SAME write_value traversal works for both sinks (a real
 * FILE* for stdout, a Port's own byte buffer otherwise) without a
 * second, buffer-specific traversal. */
static Value bi_write(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("write: expected an argument");
  if (nargs >= 2 && args[1].tag != T_PORT) cvm_abort("write: expected a port");
  char *buf = NULL;
  size_t size = 0;
  FILE *ms = open_memstream(&buf, &size);
  write_value(ms, args[0]);
  fclose(ms);
  Port *p = (nargs >= 2) ? args[1].as.port : &stdout_port_sentinel;
  if (p->kind == PORT_KIND_STDOUT || p->kind == PORT_KIND_OUTPUT_FILE) {
    fwrite(buf, 1, size, p->kind == PORT_KIND_STDOUT ? stdout : p->file);
  } else {
    if (p->kind != PORT_KIND_OUTPUT_STRING) cvm_abort("write: expected an output port");
    port_buf_grow(p, (int)size);
    memcpy(p->buf + p->len, buf, size);
    p->len += (int)size;
  }
  free(buf);
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
 * equal? only adds structural recursion for pairs/vectors. Not static:
 * exposed via vm.h so treelist.c's find_index (treelist-member?/
 * treelist-index-of's default equality) can reuse it instead of
 * duplicating the pair/vector recursion. */
int cvm_equal(Value a, Value b) {
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

/* Shared by vector-copy/-copy!/-fill! below for their optional (start end)
 * args -- mirrors src/scheme/modules/scheme/base/vectors.cr's own
 * seq_range_args (defaults: start 0, end len). */
static void vector_range_args(int len, Value *args, int nargs, int start_idx, int *first, int *last) {
  *first = (nargs > start_idx && args[start_idx].tag == T_INT) ? (int)args[start_idx].as.i : 0;
  *last = (nargs > start_idx + 1 && args[start_idx + 1].tag == T_INT) ? (int)args[start_idx + 1].as.i : len;
  if (*first < 0 || *last > len || *first > *last) cvm_abort("vector: start/end out of range");
}

static Value bi_vector_copy(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_VECTOR) cvm_abort("vector-copy: expected a vector");
  Vector *src = args[0].as.vec;
  int first, last;
  vector_range_args(src->len, args, nargs, 1, &first, &last);
  int n = last - first;
  Vector *vec = GC_MALLOC(sizeof(Vector));
  vec->len = n;
  vec->items = GC_MALLOC(sizeof(Value) * (size_t)(n ? n : 1));
  for (int i = 0; i < n; i++) vec->items[i] = src->items[first + i];
  return v_vector(vec);
}

static Value bi_vector_copy_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 3 || args[0].tag != T_VECTOR || args[1].tag != T_INT || args[2].tag != T_VECTOR)
    cvm_abort("vector-copy!: expected (to at from ...)");
  Vector *to = args[0].as.vec;
  int at = (int)args[1].as.i;
  Vector *from = args[2].as.vec;
  int first, last;
  vector_range_args(from->len, args, nargs, 3, &first, &last);
  int n = last - first;
  if (at < 0 || at + n > to->len) cvm_abort("vector-copy!: destination range out of bounds");
  if (to == from && at > first) {
    for (int i = n - 1; i >= 0; i--) to->items[at + i] = from->items[first + i];
  } else {
    for (int i = 0; i < n; i++) to->items[at + i] = from->items[first + i];
  }
  return v_nil();
}

static Value bi_vector_fill(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2 || args[0].tag != T_VECTOR) cvm_abort("vector-fill!: expected a vector and a fill value");
  Vector *vec = args[0].as.vec;
  Value fill = args[1];
  int first, last;
  vector_range_args(vec->len, args, nargs, 2, &first, &last);
  for (int i = first; i < last; i++) vec->items[i] = fill;
  return v_nil();
}

static Value bi_vector_append(VM *vm, Value *args, int nargs) {
  (void)vm;
  int total = 0;
  for (int i = 0; i < nargs; i++) {
    if (args[i].tag != T_VECTOR) cvm_abort("vector-append: expected a vector");
    total += args[i].as.vec->len;
  }
  Vector *vec = GC_MALLOC(sizeof(Vector));
  vec->len = total;
  vec->items = GC_MALLOC(sizeof(Value) * (size_t)(total ? total : 1));
  int pos = 0;
  for (int i = 0; i < nargs; i++) {
    Vector *src = args[i].as.vec;
    for (int j = 0; j < src->len; j++) vec->items[pos++] = src->items[j];
  }
  return v_vector(vec);
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
static Value bi_procedure_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("procedure?: expected an argument"); return v_bool(args[0].tag == T_CLOSURE || args[0].tag == T_CASE_CLOSURE || args[0].tag == T_RECORD_CALLABLE || args[0].tag == T_BUILTIN || args[0].tag == T_CONTINUATION); }
static Value bi_number_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("number?: expected an argument"); return v_bool(args[0].tag == T_INT || args[0].tag == T_FLOAT || args[0].tag == T_RATIONAL || args[0].tag == T_COMPLEX); }
/* real? is every number EXCEPT a genuine T_COMPLEX -- mirrors real?
 * (predicates.cr) exactly: number?(v) && !v.is_a?(SchemeComplex). */
static Value bi_real_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("real?: expected an argument"); return v_bool(args[0].tag == T_INT || args[0].tag == T_FLOAT || args[0].tag == T_RATIONAL); }
/* complex? is literally an alias for number? -- every number is complex
 * per R7RS (mirrors complex.cr's own complex_p exactly, "true for any
 * number, real or complex"). */
static Value bi_complex_p(VM *vm, Value *args, int nargs) { return bi_number_p(vm, args, nargs); }
static Value bi_integer_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("integer?: expected an argument");
  if (args[0].tag == T_INT) return v_bool(1);
  if (args[0].tag == T_FLOAT) return v_bool(args[0].as.f == floor(args[0].as.f));
  /* T_RATIONAL is never whole by construction (make_rational_from_mpq
   * collapses den==1 to T_INT before a T_RATIONAL Value ever exists), so
   * always false here -- mirrors integer? (predicates.cr) exactly. */
  return v_bool(0);
}
/* exact? is int/rational, matching Scheme.exact? exactly (helpers.cr);
 * complex is neither exact? nor inexact? here, same gap native itself
 * has (see complex.cr's own header comment on this not being special-
 * cased) -- not something this port is trying to fix. */
static Value bi_exact_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("exact?: expected an argument"); return v_bool(args[0].tag == T_INT || args[0].tag == T_RATIONAL); }
static Value bi_inexact_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("inexact?: expected an argument"); return v_bool(args[0].tag == T_FLOAT); }
static Value bi_exact_integer_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("exact-integer?: expected an argument"); return v_bool(args[0].tag == T_INT); }
/* rational? is exact (int/rational) OR a finite float -- mirrors
 * rational? (predicates.cr) exactly. Needed by modules/creme/bytecode.
 * sld's own write-datum! (SCB1 chunk serialization) to detect a rational
 * constant, so this isn't just a nicety -- without it, compiling any
 * chunk containing a rational constant aborts with "unbound variable:
 * rational?" under cvm specifically (the self-hosted compiler's own
 * compile-time-constant path always goes through this). */
static Value bi_rational_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("rational?: expected an argument");
  if (args[0].tag == T_INT || args[0].tag == T_RATIONAL) return v_bool(1);
  if (args[0].tag == T_FLOAT) return v_bool(isfinite(args[0].as.f));
  return v_bool(0);
}
/* numerator/denominator -- int/rational only (matches native's own int/
 * rational cases exactly); a float argument would need native's own
 * round-trip-through-to_exact conversion, not needed by anything in this
 * project's own cvm test surface (write-datum! above only ever calls
 * these on a value it already confirmed is exact AND rational AND NOT an
 * integer, i.e. always a genuine T_RATIONAL) -- left unimplemented rather
 * than half-built. */
static Value bi_numerator(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("numerator: expected an argument");
  if (args[0].tag == T_INT) return args[0];
  if (args[0].tag == T_RATIONAL) {
    if (!mpz_fits_slong_p(mpq_numref(args[0].as.rational->q))) cvm_abort("numerator: too large for this prototype's fixnum-only int type");
    return v_int((int64_t)mpz_get_si(mpq_numref(args[0].as.rational->q)));
  }
  cvm_abort("numerator: expected an exact rational or integer");
}
static Value bi_denominator(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("denominator: expected an argument");
  if (args[0].tag == T_INT) return v_int(1);
  if (args[0].tag == T_RATIONAL) {
    if (!mpz_fits_slong_p(mpq_denref(args[0].as.rational->q))) cvm_abort("denominator: too large for this prototype's fixnum-only int type");
    return v_int((int64_t)mpz_get_si(mpq_denref(args[0].as.rational->q)));
  }
  cvm_abort("denominator: expected an exact rational or integer");
}
static Value bi_eq_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 2) cvm_abort("eq?: expected two arguments"); return v_bool(cvm_eqv(args[0], args[1])); }
static Value bi_eqv_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 2) cvm_abort("eqv?: expected two arguments"); return v_bool(cvm_eqv(args[0], args[1])); }
static Value bi_equal_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 2) cvm_abort("equal?: expected two arguments"); return v_bool(cvm_equal(args[0], args[1])); }

/* ---- numeric predicates / conversions ---- */
/* zero?/positive?/negative?/abs all extend to T_RATIONAL below (mpq_sgn/
 * a fresh mpq_t with its numerator negated) -- floor/ceiling/round/
 * truncate of a rational used to be cut here too; see bi_floor/
 * bi_ceiling/bi_round/bi_truncate below for their own T_RATIONAL
 * handling. abs/zero?/positive?/negative? of a T_COMPLEX deliberately
 * stay unimplemented here, matching the native Crystal interpreter's own
 * behavior exactly (src/scheme/modules/scheme/base/arithmetic.cr's abs
 * and base/predicates.cr's zero?/positive?/negative? don't accept a
 * complex value either -- (scheme complex)'s magnitude has its own
 * separate complex-aware sqrt(re^2+im^2) logic instead) -- this is
 * parity with native, not a remaining gap. */
static Value bi_zero_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("zero?: expected an argument");
  if (args[0].tag == T_INT) return v_bool(args[0].as.i == 0);
  if (args[0].tag == T_FLOAT) return v_bool(args[0].as.f == 0.0);
  if (args[0].tag == T_RATIONAL) return v_bool(0); /* never zero, see value.h */
  cvm_abort("zero?: not a number");
}
static Value bi_positive_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("positive?: expected an argument");
  if (args[0].tag == T_INT) return v_bool(args[0].as.i > 0);
  if (args[0].tag == T_FLOAT) return v_bool(args[0].as.f > 0.0);
  if (args[0].tag == T_RATIONAL) return v_bool(mpq_sgn(args[0].as.rational->q) > 0);
  cvm_abort("positive?: not a number");
}
static Value bi_negative_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("negative?: expected an argument");
  if (args[0].tag == T_INT) return v_bool(args[0].as.i < 0);
  if (args[0].tag == T_FLOAT) return v_bool(args[0].as.f < 0.0);
  if (args[0].tag == T_RATIONAL) return v_bool(mpq_sgn(args[0].as.rational->q) < 0);
  cvm_abort("negative?: not a number");
}
static Value bi_odd_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1 || args[0].tag != T_INT) cvm_abort("odd?: expected an integer"); return v_bool(args[0].as.i % 2 != 0); }
static Value bi_even_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1 || args[0].tag != T_INT) cvm_abort("even?: expected an integer"); return v_bool(args[0].as.i % 2 == 0); }
static Value bi_abs(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("abs: expected an argument");
  if (args[0].tag == T_INT) return v_int(args[0].as.i < 0 ? -args[0].as.i : args[0].as.i);
  if (args[0].tag == T_FLOAT) return v_float(fabs(args[0].as.f));
  if (args[0].tag == T_RATIONAL) {
    if (mpq_sgn(args[0].as.rational->q) >= 0) return args[0];
    mpq_t q;
    mpq_init(q);
    mpq_neg(q, args[0].as.rational->q);
    Value result = make_rational_from_mpq(q);
    mpq_clear(q);
    return result;
  }
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
/* floor/ceiling/truncate/round of a T_RATIONAL: GMP has no mpq_floor, so
 * divide numerator by denominator directly via mpz_fdiv_q/mpz_cdiv_q/
 * mpz_tdiv_q -- the denominator is always positive by construction (see
 * value.h's canonical-form comment on Rational), so these floor-toward-
 * negative-infinity/ceiling-toward-positive-infinity/truncate-toward-zero
 * GMP primitives line up exactly with R7RS's own floor/ceiling/truncate.
 * Result is always exact and integral, so always collapses to a T_INT. */
static Value mpz_to_int_value(mpz_t z, const char *who) {
  if (!mpz_fits_slong_p(z)) cvm_abort("%s: result too large for this prototype's fixnum-only int type", who);
  return v_int((int64_t)mpz_get_si(z));
}

static Value bi_round(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("round: expected an argument");
  if (args[0].tag == T_INT) return args[0];
  if (args[0].tag == T_FLOAT) return v_float(round(args[0].as.f));
  if (args[0].tag == T_RATIONAL) {
    mpq_t *q = &args[0].as.rational->q;
    mpz_t floor_q, rem2, twice_rem;
    mpz_inits(floor_q, rem2, twice_rem, NULL);
    /* floor_q = floor(n/d), rem2 = n - floor_q*d (the remainder, always
     * in [0, d) since mpz_fdiv_qr rounds toward -infinity). */
    mpz_fdiv_qr(floor_q, rem2, mpq_numref(*q), mpq_denref(*q));
    mpz_mul_2exp(twice_rem, rem2, 1); /* twice_rem = 2*rem2 */
    int cmp = mpz_cmp(twice_rem, mpq_denref(*q));
    /* Round-half-to-even: below the midpoint keeps floor_q; above it
     * takes floor_q+1; exactly at it goes to whichever of the two is
     * even (R7RS's own tie-breaking rule for `round`). */
    if (cmp > 0 || (cmp == 0 && mpz_odd_p(floor_q))) mpz_add_ui(floor_q, floor_q, 1);
    Value result = mpz_to_int_value(floor_q, "round");
    mpz_clears(floor_q, rem2, twice_rem, NULL);
    return result;
  }
  cvm_abort("round: not a number");
}
static Value bi_floor(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("floor: expected an argument");
  if (args[0].tag == T_INT) return args[0];
  if (args[0].tag == T_FLOAT) return v_float(floor(args[0].as.f));
  if (args[0].tag == T_RATIONAL) {
    mpz_t z;
    mpz_init(z);
    mpz_fdiv_q(z, mpq_numref(args[0].as.rational->q), mpq_denref(args[0].as.rational->q));
    Value result = mpz_to_int_value(z, "floor");
    mpz_clear(z);
    return result;
  }
  cvm_abort("floor: not a number");
}
static Value bi_ceiling(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("ceiling: expected an argument");
  if (args[0].tag == T_INT) return args[0];
  if (args[0].tag == T_FLOAT) return v_float(ceil(args[0].as.f));
  if (args[0].tag == T_RATIONAL) {
    mpz_t z;
    mpz_init(z);
    mpz_cdiv_q(z, mpq_numref(args[0].as.rational->q), mpq_denref(args[0].as.rational->q));
    Value result = mpz_to_int_value(z, "ceiling");
    mpz_clear(z);
    return result;
  }
  cvm_abort("ceiling: not a number");
}
static Value bi_truncate(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("truncate: expected an argument");
  if (args[0].tag == T_INT) return args[0];
  if (args[0].tag == T_FLOAT) return v_float(trunc(args[0].as.f));
  if (args[0].tag == T_RATIONAL) {
    mpz_t z;
    mpz_init(z);
    mpz_tdiv_q(z, mpq_numref(args[0].as.rational->q), mpq_denref(args[0].as.rational->q));
    Value result = mpz_to_int_value(z, "truncate");
    mpz_clear(z);
    return result;
  }
  cvm_abort("truncate: not a number");
}
static Value bi_exact(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("exact: expected an argument");
  if (args[0].tag == T_INT || args[0].tag == T_RATIONAL) return args[0];
  /* Truncates rather than finding the float's own exact rational value
   * (native's to_exact does the latter via BigRational -- see
   * builtin_helpers.cr) -- a pre-existing simplification of this
   * prototype's inexact->exact, unchanged/not in scope here. */
  if (args[0].tag == T_FLOAT) return v_int((int64_t)args[0].as.f);
  cvm_abort("exact: not a number");
}
static Value bi_inexact(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("inexact: expected an argument");
  if (args[0].tag == T_FLOAT) return args[0];
  if (args[0].tag == T_INT) return v_float((double)args[0].as.i);
  if (args[0].tag == T_RATIONAL) return v_float(mpq_get_d(args[0].as.rational->q));
  cvm_abort("inexact: not a number");
}

/* ---- (scheme complex) -- mirrors src/scheme/modules/scheme/complex.cr's
 * own small surface exactly (make-rectangular/make-polar/real-part/
 * imag-part/magnitude/angle); complex?/number? are above, alongside the
 * other predicates. This IS the complete native surface, not a subset --
 * nothing was left out here. ---- */
static int is_real_component(Value v) { return v.tag == T_INT || v.tag == T_FLOAT || v.tag == T_RATIONAL; }

static Value bi_make_rectangular(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 2 || !is_real_component(args[0]) || !is_real_component(args[1])) {
    cvm_abort("make-rectangular: expected two real numbers");
  }
  return make_complex(args[0], args[1]);
}

static Value bi_make_polar(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 2) cvm_abort("make-polar: expected (magnitude angle)");
  double mag = as_double(args[0], "make-polar"), ang = as_double(args[1], "make-polar");
  return make_complex(v_float(mag * cos(ang)), v_float(mag * sin(ang)));
}

static Value bi_real_part(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 1) cvm_abort("real-part: expected an argument");
  if (args[0].tag == T_COMPLEX) return args[0].as.cplx->real;
  if (!is_real_component(args[0])) cvm_abort("real-part: not a number");
  return args[0];
}

static Value bi_imag_part(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 1) cvm_abort("imag-part: expected an argument");
  if (args[0].tag == T_COMPLEX) return args[0].as.cplx->imag;
  if (!is_real_component(args[0])) cvm_abort("imag-part: not a number");
  return v_int(0);
}

static Value bi_magnitude(VM *vm, Value *args, int nargs) {
  if (nargs != 1) cvm_abort("magnitude: expected an argument");
  if (args[0].tag == T_COMPLEX) {
    double re = as_double(args[0].as.cplx->real, "magnitude"), im = as_double(args[0].as.cplx->imag, "magnitude");
    return v_float(sqrt(re * re + im * im));
  }
  return bi_abs(vm, args, nargs);
}

static Value bi_angle(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 1) cvm_abort("angle: expected an argument");
  if (args[0].tag == T_COMPLEX) {
    return v_float(atan2(as_double(args[0].as.cplx->imag, "angle"), as_double(args[0].as.cplx->real, "angle")));
  }
  if (!is_real_component(args[0])) cvm_abort("angle: not a number");
  return v_float(as_double(args[0], "angle") < 0 ? M_PI : 0.0);
}

/* ---- pairs / lists ---- */
static Value bi_car(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1 || args[0].tag != T_PAIR) cvm_abort("car: expected a pair"); return args[0].as.pair->car; }
static Value bi_cdr(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1 || args[0].tag != T_PAIR) cvm_abort("cdr: expected a pair"); return args[0].as.pair->cdr; }

/* set-car!/set-cdr! -- mutate a Pair's own field in place (Pair is a
 * real, individually GC_MALLOC'd struct -- see value.h -- so this is
 * just a direct field write, no copy-on-write or interning to worry
 * about); return unspecified (v_nil()), matching native's own contract
 * exactly. Like native, this does NOT detect/reject mutating a literal
 * constant (R7RS documents that as an error, but neither implementation
 * enforces it -- see cvm/README.md's own note on this, mirroring the
 * Crystal-side spec suite's identical pending case). */
static Value bi_set_car_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2 || args[0].tag != T_PAIR) cvm_abort("set-car!: expected a pair");
  args[0].as.pair->car = args[1];
  return v_nil();
}
static Value bi_set_cdr_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2 || args[0].tag != T_PAIR) cvm_abort("set-cdr!: expected a pair");
  args[0].as.pair->cdr = args[1];
  return v_nil();
}

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

/* (dynamic-wind before thunk after) -- reuses the SAME unwind_stack
 * mechanism parameterize's own Op::PARAMPUSH/PARAMPOP already use (see
 * vm.h's own UnwindAction/UnwindKind doc comment), generalized to also
 * support "call this after-thunk" alongside "restore these parameters".
 * Pushing our own UnwindAction BEFORE calling thunk means an error
 * raised (anywhere, however deep, including through further nested
 * cvm_apply calls) that unwinds past this dynamic-wind via an outer
 * guard handler will run `after` during that handler's own unwind-stack
 * drain (OP_PUSHHANDLER's resume branch) -- exactly like a pending
 * parameterize restoration -- even though this C function's own call
 * frame never returns normally in that case (longjmp bypasses it
 * entirely). On the ordinary, no-exception path, thunk returns normally
 * here and we pop + run our own action directly. */
static Value bi_dynamic_wind(VM *vm, Value *args, int nargs) {
  if (nargs != 3) cvm_abort("dynamic-wind: expected (before thunk after)");
  Value before = args[0], thunk = args[1], after = args[2];
  cvm_apply(vm, before, NULL, 0);
  if (vm->n_unwind >= CVM_UNWIND_CAP) cvm_abort("cvm: parameterize/dynamic-wind unwind stack full (CVM_UNWIND_CAP=%d)", CVM_UNWIND_CAP);
  UnwindAction *ua = &vm->unwind_stack[vm->n_unwind++];
  ua->kind = UNWIND_DYNAMIC_WIND;
  ua->after = after;
  Value result = cvm_apply(vm, thunk, NULL, 0);
  /* Ordinary, no-exception return: pop our own action and run `after`
   * directly here (NOT via vm.c's own run_unwind_action, static/private
   * to that file -- this is the exact same one-line effect for the
   * DYNAMIC_WIND case). The guard-unwind path (vm.c) still handles the
   * exceptional case via that same UnwindAction, unaffected by this. */
  vm->n_unwind--;
  cvm_apply(vm, after, NULL, 0);
  return result;
}

/* (call/cc proc) / (call-with-current-continuation proc) -- an ESCAPE-
 * ONLY (one-shot, upward) continuation: captures the current point via
 * setjmp, wraps it in a T_CONTINUATION Value, and calls `proc` with it
 * as the sole argument. If `proc` returns normally (never invokes the
 * continuation), call/cc itself returns that value, same as an ordinary
 * call. If the continuation IS invoked (immediately, or arbitrarily
 * deep -- through further nested cvm_apply calls, e.g. a for-each
 * callback), dispatch_call/cvm_apply's own T_CONTINUATION case (vm.c)
 * unwinds pending dynamic-wind/parameterize actions and longjmps
 * straight back to the setjmp call site below, which returns k->result
 * instead. See value.h's own Continuation doc comment for why this is
 * NOT a general re-enterable continuation. */
static Value bi_call_cc(VM *vm, Value *args, int nargs) {
  if (nargs != 1) cvm_abort("call/cc: expected a procedure");
  Continuation *k = GC_MALLOC(sizeof(Continuation));
  k->depth = vm->depth;
  k->unwind_mark = vm->n_unwind;
  if (setjmp(k->buf) != 0) return k->result;
  Value kval = v_continuation(k);
  return cvm_apply(vm, args[0], &kval, 1);
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
static Value bi_vector_map(VM *vm, Value *args, int nargs) {
  if (nargs < 2) cvm_abort("vector-map: expected a procedure and at least one vector");
  int n_vecs = nargs - 1;
  int minlen = -1;
  for (int i = 0; i < n_vecs; i++) {
    if (args[1 + i].tag != T_VECTOR) cvm_abort("vector-map: expected a vector");
    int len = args[1 + i].as.vec->len;
    if (minlen < 0 || len < minlen) minlen = len;
  }
  Vector *result = GC_MALLOC(sizeof(Vector));
  result->len = minlen;
  result->items = GC_MALLOC(sizeof(Value) * (size_t)(minlen ? minlen : 1));
  Value *items = malloc(sizeof(Value) * (size_t)n_vecs);
  for (int i = 0; i < minlen; i++) {
    for (int j = 0; j < n_vecs; j++) items[j] = args[1 + j].as.vec->items[i];
    result->items[i] = cvm_apply(vm, args[0], items, n_vecs);
  }
  free(items);
  return v_vector(result);
}
static Value bi_vector_for_each(VM *vm, Value *args, int nargs) {
  if (nargs < 2) cvm_abort("vector-for-each: expected a procedure and at least one vector");
  int n_vecs = nargs - 1;
  int minlen = -1;
  for (int i = 0; i < n_vecs; i++) {
    if (args[1 + i].tag != T_VECTOR) cvm_abort("vector-for-each: expected a vector");
    int len = args[1 + i].as.vec->len;
    if (minlen < 0 || len < minlen) minlen = len;
  }
  Value *items = malloc(sizeof(Value) * (size_t)n_vecs);
  for (int i = 0; i < minlen; i++) {
    for (int j = 0; j < n_vecs; j++) items[j] = args[1 + j].as.vec->items[i];
    cvm_apply(vm, args[0], items, n_vecs);
  }
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

/* Byte-wise lexicographic compare of two T_STR values, length-aware (no
 * nul-termination assumption) -- same shape as string_ci_pair_cmp
 * (char.cr's own string-ci* comparisons) but without lowering either
 * side first. */
static int string_pair_cmp(Value a, Value b) {
  int alen = a.as.str.len, blen = b.as.str.len;
  int n = alen < blen ? alen : blen;
  int c = n ? memcmp(a.as.str.chars, b.as.str.chars, (size_t)n) : 0;
  if (c != 0) return c;
  return alen == blen ? 0 : (alen < blen ? -1 : 1);
}
static Value string_chain(Value *args, int nargs, const char *who, int (*ok)(int)) {
  if (nargs < 2) cvm_abort("%s: expected at least two strings", who);
  for (int i = 1; i < nargs; i++) {
    if (args[i - 1].tag != T_STR || args[i].tag != T_STR) cvm_abort("%s: expected strings", who);
    if (!ok(string_pair_cmp(args[i - 1], args[i]))) return v_bool(0);
  }
  return v_bool(1);
}
/* Same shape as char.cr's own sci_lt/sci_gt/sci_le/sci_ge (defined later
 * in this file, so not forward-visible here) -- a plain "is this memcmp-
 * style result negative/positive/etc." predicate. */
static int str_lt(int c) { return c < 0; }
static int str_gt(int c) { return c > 0; }
static int str_le(int c) { return c <= 0; }
static int str_ge(int c) { return c >= 0; }
static Value bi_string_lt(VM *vm, Value *args, int nargs) { (void)vm; return string_chain(args, nargs, "string<?", str_lt); }
static Value bi_string_gt(VM *vm, Value *args, int nargs) { (void)vm; return string_chain(args, nargs, "string>?", str_gt); }
static Value bi_string_le(VM *vm, Value *args, int nargs) { (void)vm; return string_chain(args, nargs, "string<=?", str_le); }
static Value bi_string_ge(VM *vm, Value *args, int nargs) { (void)vm; return string_chain(args, nargs, "string>=?", str_ge); }

static Value bi_symbol_eq(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2) cvm_abort("symbol=?: expected at least two symbols");
  for (int i = 1; i < nargs; i++) {
    if (args[i - 1].tag != T_SYM || args[i].tag != T_SYM) cvm_abort("symbol=?: expected symbols");
    if (args[i - 1].as.str.len != args[i].as.str.len ||
        memcmp(args[i - 1].as.str.chars, args[i].as.str.chars, (size_t)args[i].as.str.len) != 0) {
      return v_bool(0);
    }
  }
  return v_bool(1);
}

static Value bi_boolean_eq(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2) cvm_abort("boolean=?: expected at least two booleans");
  for (int i = 1; i < nargs; i++) {
    if (args[i - 1].tag != T_BOOL || args[i].tag != T_BOOL) cvm_abort("boolean=?: expected booleans");
    if (args[i - 1].as.b != args[i].as.b) return v_bool(0);
  }
  return v_bool(1);
}

/* (string-map proc str1 str2 ...): applies proc across the Nth char of
 * every string argument (stopping at the shortest one), building a new
 * string from proc's own char results -- mirrors native's own
 * string_map exactly (min length, one call per index). */
static Value bi_string_map(VM *vm, Value *args, int nargs) {
  if (nargs < 2) cvm_abort("string-map: expected (proc string ...)");
  int nstrs = nargs - 1;
  int minlen = -1;
  for (int i = 1; i < nargs; i++) {
    if (args[i].tag != T_STR) cvm_abort("string-map: expected a string");
    if (minlen < 0 || args[i].as.str.len < minlen) minlen = args[i].as.str.len;
  }
  char *buf = GC_MALLOC((size_t)(minlen ? minlen : 1));
  Value *call_args = GC_MALLOC(sizeof(Value) * (size_t)nstrs);
  for (int i = 0; i < minlen; i++) {
    for (int s = 0; s < nstrs; s++) call_args[s] = v_char((unsigned char)args[1 + s].as.str.chars[i]);
    Value result = cvm_apply(vm, args[0], call_args, nstrs);
    if (result.tag != T_CHAR) cvm_abort("string-map: expected the function to return a char");
    buf[i] = (char)result.as.i;
  }
  return v_str(buf, minlen);
}

/* (string-copy! to at from [start [end]]): cvm strings are mutable byte
 * buffers (see string-set!'s own in-place write) -- memmove (not
 * memcpy) since `to` and `from` may be the SAME string with an
 * overlapping range. */
static Value bi_string_copy_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 3 || args[0].tag != T_STR || args[1].tag != T_INT || args[2].tag != T_STR)
    cvm_abort("string-copy!: expected (to at from [start [end]])");
  int at = (int)args[1].as.i;
  int first, last;
  byte_range_args(args, nargs, 3, args[2].as.str.len, &first, &last);
  int count = last - first;
  if (at < 0 || at + count > args[0].as.str.len) cvm_abort("string-copy!: destination range out of bounds");
  memmove((char *)args[0].as.str.chars + at, args[2].as.str.chars + first, (size_t)count);
  return v_nil();
}

static Value bi_string_fill_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2 || args[0].tag != T_STR || args[1].tag != T_CHAR) cvm_abort("string-fill!: expected (string char [start [end]])");
  int first, last;
  byte_range_args(args, nargs, 2, args[0].as.str.len, &first, &last);
  memset((char *)args[0].as.str.chars + first, (int)(unsigned char)args[1].as.i, (size_t)(last - first));
  return v_nil();
}

static Value bi_string_to_vector(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) cvm_abort("string->vector: expected a string");
  int first, last;
  byte_range_args(args, nargs, 1, args[0].as.str.len, &first, &last);
  int len = last - first;
  Vector *vec = GC_MALLOC(sizeof(Vector));
  vec->len = len;
  vec->items = GC_MALLOC(sizeof(Value) * (size_t)(len ? len : 1));
  for (int i = 0; i < len; i++) vec->items[i] = v_char((unsigned char)args[0].as.str.chars[first + i]);
  return v_vector(vec);
}

static Value bi_vector_to_string(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_VECTOR) cvm_abort("vector->string: expected a vector");
  Vector *vec = args[0].as.vec;
  int first, last;
  byte_range_args(args, nargs, 1, vec->len, &first, &last);
  int len = last - first;
  char *buf = GC_MALLOC((size_t)(len ? len : 1));
  for (int i = 0; i < len; i++) {
    if (vec->items[first + i].tag != T_CHAR) cvm_abort("vector->string: expected a vector of chars");
    buf[i] = (char)vec->items[first + i].as.i;
  }
  return v_str(buf, len);
}
/* Optional 2nd arg: an explicit radix (2/8/10/16), needed by (creme
 * compiler reader)'s own #b/#o/#x-prefixed literal parsing -- previously
 * silently ignored here (always base 10), so a hex/octal/binary literal
 * whose digits aren't ALSO valid decimal digits (e.g. "1A" for #x1A)
 * failed to parse under cvm specifically (reader.sld delegates the
 * actual digit-parsing to this builtin). Floats only ever make sense in
 * base 10 (R7RS has no hex/octal/binary float syntax), so strtod is only
 * tried there. */
static Value bi_string_to_number(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) cvm_abort("string->number: expected a string");
  int radix = 10;
  if (nargs >= 2) {
    if (args[1].tag != T_INT) cvm_abort("string->number: expected an integer radix");
    radix = (int)args[1].as.i;
  }
  int len = args[0].as.str.len;
  char *buf = malloc((size_t)len + 1);
  memcpy(buf, args[0].as.str.chars, (size_t)len);
  buf[len] = 0;
  char *endptr;
  long long iv = strtoll(buf, &endptr, radix);
  if (endptr != buf && *endptr == 0) { free(buf); return v_int(iv); }
  if (radix == 10) {
    double dv = strtod(buf, &endptr);
    if (endptr != buf && *endptr == 0) { free(buf); return v_float(dv); }
  }
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

/* (creme introspection)'s gensym -- a distinct symbol each call
 * ("prefix__N", N a process-wide counter), needed by defmacro-based
 * capture-avoidance idioms (e.g. modules/creme/compiler/compiler.sld's
 * own swap!-with-gensym pattern, exercised directly by spec/creme/
 * macro_spec.scm). Mirrors src/scheme/modules/scheme/base/misc.cr's own
 * gensym exactly (prefix defaults to "g" with no argument). */
static int64_t g_gensym_counter = 0;
static Value bi_gensym(VM *vm, Value *args, int nargs) {
  (void)vm;
  const char *prefix_chars = "g";
  int prefix_len = 1;
  if (nargs >= 1) {
    if (args[0].tag != T_STR && args[0].tag != T_SYM) cvm_abort("gensym: expected a string or symbol prefix");
    prefix_chars = args[0].as.str.chars;
    prefix_len = args[0].as.str.len;
  }
  g_gensym_counter++;
  int cap = prefix_len + 32;
  char *buf = GC_MALLOC((size_t)cap);
  int n = snprintf(buf, (size_t)cap, "%.*s__%lld", prefix_len, prefix_chars, (long long)g_gensym_counter);
  return v_sym(buf, n);
}
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

/* ---- (scheme char): classification, foldcase, case-insensitive
 * comparisons -- ASCII-only, same scope as char-upcase/char-downcase
 * above and strings.c's own string-upcase/string-downcase. */

/* Native's char-foldcase is literally the same as char-downcase (its own
 * comment: "correct for the ASCII/simple-Unicode range this interpreter
 * otherwise handles") -- reuses bi_char_downcase's own logic rather than
 * duplicating it. */
static Value bi_char_foldcase(VM *vm, Value *args, int nargs) {
  return bi_char_downcase(vm, args, nargs);
}

static Value bi_digit_value(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_CHAR) cvm_abort("digit-value: expected a char");
  int64_t c = args[0].as.i;
  return (c >= '0' && c <= '9') ? v_int(c - '0') : v_bool(0);
}

static Value bi_char_alphabetic_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_CHAR) cvm_abort("char-alphabetic?: expected a char");
  return v_bool(isalpha((int)args[0].as.i) != 0);
}

static Value bi_char_numeric_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_CHAR) cvm_abort("char-numeric?: expected a char");
  return v_bool(isdigit((int)args[0].as.i) != 0);
}

static Value bi_char_whitespace_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_CHAR) cvm_abort("char-whitespace?: expected a char");
  return v_bool(isspace((int)args[0].as.i) != 0);
}

static Value bi_char_upper_case_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_CHAR) cvm_abort("char-upper-case?: expected a char");
  return v_bool(isupper((int)args[0].as.i) != 0);
}

static Value bi_char_lower_case_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_CHAR) cvm_abort("char-lower-case?: expected a char");
  return v_bool(islower((int)args[0].as.i) != 0);
}

static char cvm_ascii_lower(char c) { return (c >= 'A' && c <= 'Z') ? (char)(c - 'A' + 'a') : c; }

/* char-ci=?/</>/<=/>= chain comparisons -- lowers both sides of each
 * adjacent pair before comparing, mirroring native's char_chain(...,
 * case_insensitive: true). */
static Value char_ci_chain(Value *args, int nargs, const char *who, int (*cmp)(char, char)) {
  if (nargs < 2) cvm_abort("%s: expected at least two chars", who);
  for (int i = 1; i < nargs; i++) {
    if (args[i - 1].tag != T_CHAR || args[i].tag != T_CHAR) cvm_abort("%s: expected chars", who);
    char a = cvm_ascii_lower((char)args[i - 1].as.i), b = cvm_ascii_lower((char)args[i].as.i);
    if (!cmp(a, b)) return v_bool(0);
  }
  return v_bool(1);
}
static int ci_eq(char a, char b) { return a == b; }
static int ci_lt(char a, char b) { return a < b; }
static int ci_gt(char a, char b) { return a > b; }
static int ci_le(char a, char b) { return a <= b; }
static int ci_ge(char a, char b) { return a >= b; }

static Value bi_char_ci_eq(VM *vm, Value *args, int nargs) { (void)vm; return char_ci_chain(args, nargs, "char-ci=?", ci_eq); }
static Value bi_char_ci_lt(VM *vm, Value *args, int nargs) { (void)vm; return char_ci_chain(args, nargs, "char-ci<?", ci_lt); }
static Value bi_char_ci_gt(VM *vm, Value *args, int nargs) { (void)vm; return char_ci_chain(args, nargs, "char-ci>?", ci_gt); }
static Value bi_char_ci_le(VM *vm, Value *args, int nargs) { (void)vm; return char_ci_chain(args, nargs, "char-ci<=?", ci_le); }
static Value bi_char_ci_ge(VM *vm, Value *args, int nargs) { (void)vm; return char_ci_chain(args, nargs, "char-ci>=?", ci_ge); }

/* string-ci=?/</>/<=/>= -- byte-wise lexicographic comparison of each
 * adjacent pair after lowering, aware of each string's own length (no
 * nul-termination assumption, unlike strcasecmp/strncasecmp). Equality
 * additionally requires equal length (a length mismatch can still
 * compare < or > via the shared prefix, same as plain strcmp semantics). */
static int string_ci_pair_cmp(Value a, Value b) {
  int alen = a.as.str.len, blen = b.as.str.len;
  int n = alen < blen ? alen : blen;
  for (int i = 0; i < n; i++) {
    char ca = cvm_ascii_lower(a.as.str.chars[i]), cb = cvm_ascii_lower(b.as.str.chars[i]);
    if (ca != cb) return ca < cb ? -1 : 1;
  }
  return alen == blen ? 0 : (alen < blen ? -1 : 1);
}
static Value string_ci_chain(Value *args, int nargs, const char *who, int (*ok)(int)) {
  if (nargs < 2) cvm_abort("%s: expected at least two strings", who);
  for (int i = 1; i < nargs; i++) {
    if (args[i - 1].tag != T_STR || args[i].tag != T_STR) cvm_abort("%s: expected strings", who);
    if (!ok(string_ci_pair_cmp(args[i - 1], args[i]))) return v_bool(0);
  }
  return v_bool(1);
}
static int sci_eq(int c) { return c == 0; }
static int sci_lt(int c) { return c < 0; }
static int sci_gt(int c) { return c > 0; }
static int sci_le(int c) { return c <= 0; }
static int sci_ge(int c) { return c >= 0; }

static Value bi_string_ci_eq(VM *vm, Value *args, int nargs) { (void)vm; return string_ci_chain(args, nargs, "string-ci=?", sci_eq); }
static Value bi_string_ci_lt(VM *vm, Value *args, int nargs) { (void)vm; return string_ci_chain(args, nargs, "string-ci<?", sci_lt); }
static Value bi_string_ci_gt(VM *vm, Value *args, int nargs) { (void)vm; return string_ci_chain(args, nargs, "string-ci>?", sci_gt); }
static Value bi_string_ci_le(VM *vm, Value *args, int nargs) { (void)vm; return string_ci_chain(args, nargs, "string-ci<=?", sci_le); }
static Value bi_string_ci_ge(VM *vm, Value *args, int nargs) { (void)vm; return string_ci_chain(args, nargs, "string-ci>=?", sci_ge); }

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

/* (scheme time)'s remaining R7RS-mandated surface: current-jiffy/
 * jiffies-per-second (current-second, above, was already registered --
 * see its own comment; it used to read CLOCK_MONOTONIC, a bug, now
 * fixed). current-jiffy counts microseconds since this PROCESS's own
 * first call to (current-jiffy) (lazily captured on first use, via
 * CLOCK_MONOTONIC so it can't go backwards under a wall-clock adjustment)
 * -- mirrors the native Crystal interpreter's own current-jiffy exactly in
 * SHAPE (elapsed monotonic time, microsecond resolution, matching
 * jiffies-per-second = 1000000) but the two can never agree on an
 * absolute VALUE, since each is relative to its own process's start --
 * see spec/creme/time_spec.scm's own header comment on why that file
 * asserts plausibility/monotonicity rather than should-match-native?. */
static struct timespec jiffy_epoch;
static int jiffy_epoch_set = 0;

static Value bi_current_jiffy(VM *vm, Value *args, int nargs) {
  (void)vm; (void)args; (void)nargs;
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  if (!jiffy_epoch_set) {
    jiffy_epoch = ts;
    jiffy_epoch_set = 1;
  }
  int64_t micros = (int64_t)(ts.tv_sec - jiffy_epoch.tv_sec) * 1000000 +
                   ((int64_t)ts.tv_nsec - (int64_t)jiffy_epoch.tv_nsec) / 1000;
  return v_int(micros);
}

static Value bi_jiffies_per_second(VM *vm, Value *args, int nargs) {
  (void)vm; (void)args; (void)nargs;
  return v_int(1000000);
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

/* (creme env)'s set-environment-variable! -- a subprocess spawned via
 * process-run (cvm/process.c) inherits its parent's environ automatically
 * (execvp doesn't touch it), so this is the one piece needed for a
 * cvm-run parent to pass a flag down to a cvm-run child it spawns (e.g.
 * spec/creme/main_spec.scm setting CREME_SPEC_DATA_MODE before spawning
 * each spec file). */
static Value bi_set_environment_variable(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2 || args[0].tag != T_STR || args[1].tag != T_STR) {
    cvm_abort("set-environment-variable!: expected two strings");
  }
  char *name = malloc((size_t)args[0].as.str.len + 1);
  memcpy(name, args[0].as.str.chars, (size_t)args[0].as.str.len);
  name[args[0].as.str.len] = 0;
  char *val = malloc((size_t)args[1].as.str.len + 1);
  memcpy(val, args[1].as.str.chars, (size_t)args[1].as.str.len);
  val[args[1].as.str.len] = 0;
  setenv(name, val, 1);
  free(name);
  free(val);
  return v_nil();
}

/* Whether STDOUT is an actual terminal, not a pipe/redirected file -- see
 * src/scheme/modules/creme/introspection.cr's own stdout_tty_p for the same
 * builtin natively; kept in sync so (creme spec)'s color decision behaves
 * identically under bin/creme, --self-hosted, and cvm/cvm. */
static Value bi_stdout_tty(VM *vm, Value *args, int nargs) {
  (void)vm; (void)args; (void)nargs;
  return v_bool(isatty(STDOUT_FILENO));
}

/* (exit [code]) -- code defaults to 0, clamped to 0-255 like native's own
 * (process_context.cr). Unlike native (which raises a SchemeExit that
 * unwinds through any pending dynamic-wind after-thunks before main.cr
 * turns it into a real process exit), this calls the raw C exit()
 * directly -- no dynamic-wind unwinding. Needed by (creme spec)'s
 * spec-summary!, always the LAST form a spec/creme test file runs, so
 * no pending dynamic-wind is realistically in scope at that point;
 * acceptable for this prototype VM's own established scope (see this
 * file's other comments on what's simplified here vs. native). */
static Value bi_exit(VM *vm, Value *args, int nargs) {
  (void)vm;
  int64_t code = 0;
  if (nargs >= 1) {
    if (args[0].tag != T_INT) cvm_abort("exit: expected an integer");
    code = args[0].as.i;
  }
  if (code < 0) code = 0;
  if (code > 255) code = 255;
  exit((int)code);
}

void cvm_register_builtins(VM *vm) {
  cvm_register_builtin(vm, "make-vector", bi_make_vector);
  cvm_register_builtin(vm, "current-second", bi_current_second);
  cvm_register_builtin(vm, "flonum->bits", bi_flonum_to_bits);
  cvm_register_builtin(vm, "bits->flonum", bi_bits_to_flonum);
  cvm_register_builtin(vm, "sin", bi_sin);
  cvm_register_builtin(vm, "cos", bi_cos);
  cvm_register_builtin(vm, "tan", bi_tan);
  cvm_register_builtin(vm, "asin", bi_asin);
  cvm_register_builtin(vm, "acos", bi_acos);
  cvm_register_builtin(vm, "atan", bi_atan);
  cvm_register_builtin(vm, "log", bi_log);
  cvm_register_builtin(vm, "exp", bi_exp);
  cvm_register_builtin(vm, "log2", bi_log2);
  cvm_register_builtin(vm, "log10", bi_log10);
  cvm_register_builtin(vm, "atan2", bi_atan2);
  cvm_register_builtin(vm, "pow", bi_pow);
  cvm_register_builtin(vm, "hypot", bi_hypot);
  cvm_register_builtin(vm, "sqrt", bi_sqrt);
  cvm_register_builtin(vm, "nan?", bi_nan_p);
  cvm_register_builtin(vm, "infinite?", bi_infinite_p);
  cvm_register_builtin(vm, "finite?", bi_finite_p);
  cvm_register_builtin(vm, "random-real", bi_random_real);
  cvm_register_builtin(vm, "random-integer", bi_random_integer);
  cvm_register_builtin(vm, "random-seed!", bi_random_seed_bang);
  cvm_register_builtin(vm, "random-choice", bi_random_choice);
  cvm_register_builtin(vm, "random-shuffle", bi_random_shuffle);
  /* pi/e are value constants, not procedures -- interned directly into
   * the global table (mirroring cvm_register_builtin's own two-line
   * shape) rather than through a BuiltinFn, matching how native's own
   * register_library block does `env.define("pi", ...)` alongside its
   * register_module calls (see creme/math.cr). */
  {
    int pi_slot = cvm_global_intern(vm, "pi", 2);
    vm->globals[pi_slot].value = v_float(M_PI);
    vm->globals[pi_slot].bound = 1;
    int e_slot = cvm_global_intern(vm, "e", 1);
    vm->globals[e_slot].value = v_float(M_E);
    vm->globals[e_slot].bound = 1;
  }
  cvm_register_builtin(vm, "display", bi_display);
  cvm_register_builtin(vm, "newline", bi_newline);
  cvm_register_builtin(vm, "open-output-string", bi_open_output_string);
  cvm_register_builtin(vm, "get-output-string", bi_get_output_string);
  cvm_register_builtin(vm, "string-length", bi_string_length);
  cvm_register_builtin(vm, "write-string", bi_write_string);
  cvm_register_builtin(vm, "write-char", bi_write_char);
  cvm_register_builtin(vm, "write", bi_write);
  cvm_register_builtin(vm, "reverse", bi_reverse);
  cvm_register_builtin(vm, "length", bi_length);
  cvm_register_builtin(vm, "current-output-port", bi_current_output_port);
  cvm_register_builtin(vm, "current-input-port", bi_current_input_port);
  cvm_register_builtin(vm, "open-input-string", bi_open_input_string);
  cvm_register_builtin(vm, "port?", bi_port_p);
  cvm_register_builtin(vm, "input-port?", bi_input_port_p);
  cvm_register_builtin(vm, "output-port?", bi_output_port_p);
  cvm_register_builtin(vm, "eof-object", bi_eof_object);
  cvm_register_builtin(vm, "eof-object?", bi_eof_object_p);
  cvm_register_builtin(vm, "close-port", bi_close_port);
  cvm_register_builtin(vm, "close-input-port", bi_close_port);
  cvm_register_builtin(vm, "close-output-port", bi_close_port);
  cvm_register_builtin(vm, "read-char", bi_read_char);
  cvm_register_builtin(vm, "peek-char", bi_peek_char);
  cvm_register_builtin(vm, "read-line", bi_read_line);
  cvm_register_builtin(vm, "char-ready?", bi_char_ready_p);
  cvm_register_builtin(vm, "file-exists?", bi_file_exists_p);
  cvm_register_builtin(vm, "open-input-file", bi_open_input_file);
  cvm_register_builtin(vm, "open-output-file", bi_open_output_file);
  cvm_register_builtin(vm, "call-with-input-file", bi_call_with_input_file);
  cvm_register_builtin(vm, "call-with-output-file", bi_call_with_output_file);
  cvm_register_builtin(vm, "exit", bi_exit);

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
  cvm_register_builtin(vm, "rational?", bi_rational_p);
  cvm_register_builtin(vm, "numerator", bi_numerator);
  cvm_register_builtin(vm, "denominator", bi_denominator);
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
  cvm_register_builtin(vm, "make-rectangular", bi_make_rectangular);
  cvm_register_builtin(vm, "make-polar", bi_make_polar);
  cvm_register_builtin(vm, "real-part", bi_real_part);
  cvm_register_builtin(vm, "imag-part", bi_imag_part);
  cvm_register_builtin(vm, "magnitude", bi_magnitude);
  cvm_register_builtin(vm, "angle", bi_angle);

  cvm_register_builtin(vm, "car", bi_car);
  cvm_register_builtin(vm, "cdr", bi_cdr);
  cvm_register_builtin(vm, "set-car!", bi_set_car_bang);
  cvm_register_builtin(vm, "set-cdr!", bi_set_cdr_bang);
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
  cvm_register_builtin(vm, "dynamic-wind", bi_dynamic_wind);
  cvm_register_builtin(vm, "call/cc", bi_call_cc);
  cvm_register_builtin(vm, "call-with-current-continuation", bi_call_cc);

  cvm_register_builtin(vm, "string-append", bi_string_append);
  cvm_register_builtin(vm, "substring", bi_substring);
  cvm_register_builtin(vm, "string-copy", bi_string_copy);
  cvm_register_builtin(vm, "string->list", bi_string_to_list);
  cvm_register_builtin(vm, "list->string", bi_list_to_string);
  cvm_register_builtin(vm, "make-string", bi_make_string);
  cvm_register_builtin(vm, "string", bi_string_ctor);
  cvm_register_builtin(vm, "string=?", bi_string_eq);
  cvm_register_builtin(vm, "string<?", bi_string_lt);
  cvm_register_builtin(vm, "string>?", bi_string_gt);
  cvm_register_builtin(vm, "string<=?", bi_string_le);
  cvm_register_builtin(vm, "string>=?", bi_string_ge);
  cvm_register_builtin(vm, "symbol=?", bi_symbol_eq);
  cvm_register_builtin(vm, "boolean=?", bi_boolean_eq);
  cvm_register_builtin(vm, "string-map", bi_string_map);
  cvm_register_builtin(vm, "string-copy!", bi_string_copy_bang);
  cvm_register_builtin(vm, "string-fill!", bi_string_fill_bang);
  cvm_register_builtin(vm, "string->vector", bi_string_to_vector);
  cvm_register_builtin(vm, "vector->string", bi_vector_to_string);
  cvm_register_builtin(vm, "string->number", bi_string_to_number);
  cvm_register_builtin(vm, "number->string", bi_number_to_string);
  cvm_register_builtin(vm, "string->symbol", bi_string_to_symbol);
  cvm_register_builtin(vm, "symbol->string", bi_symbol_to_string);
  cvm_register_builtin(vm, "gensym", bi_gensym);
  cvm_register_builtin(vm, "char->integer", bi_char_to_integer);
  cvm_register_builtin(vm, "integer->char", bi_integer_to_char);
  cvm_register_builtin(vm, "char=?", bi_char_eq);
  cvm_register_builtin(vm, "char<?", bi_char_lt);
  cvm_register_builtin(vm, "char>?", bi_char_gt);
  cvm_register_builtin(vm, "char<=?", bi_char_le);
  cvm_register_builtin(vm, "char>=?", bi_char_ge);
  cvm_register_builtin(vm, "char-downcase", bi_char_downcase);
  cvm_register_builtin(vm, "char-upcase", bi_char_upcase);
  cvm_register_builtin(vm, "char-foldcase", bi_char_foldcase);
  cvm_register_builtin(vm, "digit-value", bi_digit_value);
  cvm_register_builtin(vm, "char-alphabetic?", bi_char_alphabetic_p);
  cvm_register_builtin(vm, "char-numeric?", bi_char_numeric_p);
  cvm_register_builtin(vm, "char-whitespace?", bi_char_whitespace_p);
  cvm_register_builtin(vm, "char-upper-case?", bi_char_upper_case_p);
  cvm_register_builtin(vm, "char-lower-case?", bi_char_lower_case_p);
  cvm_register_builtin(vm, "char-ci=?", bi_char_ci_eq);
  cvm_register_builtin(vm, "char-ci<?", bi_char_ci_lt);
  cvm_register_builtin(vm, "char-ci>?", bi_char_ci_gt);
  cvm_register_builtin(vm, "char-ci<=?", bi_char_ci_le);
  cvm_register_builtin(vm, "char-ci>=?", bi_char_ci_ge);
  cvm_register_builtin(vm, "string-ci=?", bi_string_ci_eq);
  cvm_register_builtin(vm, "string-ci<?", bi_string_ci_lt);
  cvm_register_builtin(vm, "string-ci>?", bi_string_ci_gt);
  cvm_register_builtin(vm, "string-ci<=?", bi_string_ci_le);
  cvm_register_builtin(vm, "string-ci>=?", bi_string_ci_ge);

  cvm_register_builtin(vm, "vector", bi_vector);
  cvm_register_builtin(vm, "vector->list", bi_vector_to_list);
  cvm_register_builtin(vm, "list->vector", bi_list_to_vector);
  cvm_register_builtin(vm, "vector-map", bi_vector_map);
  cvm_register_builtin(vm, "vector-for-each", bi_vector_for_each);
  cvm_register_builtin(vm, "vector-copy", bi_vector_copy);
  cvm_register_builtin(vm, "vector-copy!", bi_vector_copy_bang);
  cvm_register_builtin(vm, "vector-fill!", bi_vector_fill);
  cvm_register_builtin(vm, "vector-append", bi_vector_append);

  cvm_register_builtin(vm, "make-bytevector", bi_make_bytevector);
  cvm_register_builtin(vm, "bytevector", bi_bytevector);
  cvm_register_builtin(vm, "bytevector-length", bi_bytevector_length);
  cvm_register_builtin(vm, "bytevector?", bi_bytevector_p);
  cvm_register_builtin(vm, "bytevector-copy", bi_bytevector_copy);
  cvm_register_builtin(vm, "bytevector-copy!", bi_bytevector_copy_bang);
  cvm_register_builtin(vm, "bytevector-append", bi_bytevector_append);
  cvm_register_builtin(vm, "utf8->string", bi_utf8_to_string);
  cvm_register_builtin(vm, "string->utf8", bi_string_to_utf8);
  cvm_register_builtin(vm, "open-input-bytevector", bi_open_input_bytevector);
  cvm_register_builtin(vm, "open-output-bytevector", bi_open_output_bytevector);
  cvm_register_builtin(vm, "get-output-bytevector", bi_get_output_bytevector);
  cvm_register_builtin(vm, "binary-port?", bi_binary_port_p);
  cvm_register_builtin(vm, "textual-port?", bi_textual_port_p);
  cvm_register_builtin(vm, "input-port-open?", bi_input_port_open_p);
  cvm_register_builtin(vm, "output-port-open?", bi_output_port_open_p);
  cvm_register_builtin(vm, "read-u8", bi_read_u8);
  cvm_register_builtin(vm, "peek-u8", bi_peek_u8);
  cvm_register_builtin(vm, "u8-ready?", bi_char_ready_p);
  cvm_register_builtin(vm, "write-u8", bi_write_u8);
  cvm_register_builtin(vm, "read-bytevector", bi_read_bytevector);
  cvm_register_builtin(vm, "read-bytevector!", bi_read_bytevector_bang);
  cvm_register_builtin(vm, "write-bytevector", bi_write_bytevector);
  cvm_register_builtin(vm, "call-with-port", bi_call_with_port);

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
  cvm_register_builtin(vm, "truncate-quotient", bi_quotient);
  cvm_register_builtin(vm, "truncate-remainder", bi_remainder);
  cvm_register_builtin(vm, "floor-quotient", bi_floor_quotient);
  cvm_register_builtin(vm, "floor-remainder", bi_modulo);
  cvm_register_builtin(vm, "truncate/", bi_truncate_slash);
  cvm_register_builtin(vm, "floor/", bi_floor_slash);
  cvm_register_builtin(vm, "gcd", bi_gcd);
  cvm_register_builtin(vm, "lcm", bi_lcm);
  cvm_register_builtin(vm, "expt", bi_expt);
  cvm_register_builtin(vm, "exact-integer-sqrt", bi_exact_integer_sqrt);
  cvm_register_builtin(vm, "+", bi_plus);
  cvm_register_builtin(vm, "-", bi_minus);
  cvm_register_builtin(vm, "*", bi_star);
  cvm_register_builtin(vm, "/", bi_slash);
  cvm_register_builtin(vm, "<", bi_num_lt);
  cvm_register_builtin(vm, ">", bi_num_gt);
  cvm_register_builtin(vm, "<=", bi_num_le);
  cvm_register_builtin(vm, ">=", bi_num_ge);
  cvm_register_builtin(vm, "=", bi_num_eq);
  cvm_register_builtin(vm, "current-time", bi_current_time);
  cvm_register_builtin(vm, "time-difference", bi_time_difference);
  cvm_register_builtin(vm, "current-jiffy", bi_current_jiffy);
  cvm_register_builtin(vm, "jiffies-per-second", bi_jiffies_per_second);
  cvm_register_builtin(vm, "get-environment-variable", bi_get_environment_variable);
  cvm_register_builtin(vm, "set-environment-variable!", bi_set_environment_variable);
  cvm_register_builtin(vm, "stdout-tty?", bi_stdout_tty);
}
