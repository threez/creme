/* The builtins competition/scheme/bench/creme.scm actually calls as plain (non-fused) global
 * procedures — see icecreme/README.md's "builtins actually called" list. Nothing
 * else is registered; calling any other name aborts with "unbound
 * variable" (see vm.c's OP_GETGLOBAL and CallGlobal arms). */
/* _XOPEN_SOURCE (before any system header): needed on glibc for
 * strptime(3) (creme time)'s string->time uses -- outside plain
 * -std=c11's default namespace there (unlike FreeBSD/Darwin libc, which
 * expose it unconditionally). */
#define _XOPEN_SOURCE 700
#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

#include <gc.h>

#include "embed.h"
#include "profiler.h"
#include "vm.h"

/* Every remaining xmalloc call site is a short-lived C string handed to
 * fopen/access/getenv/setenv/execvp and free(3)'d before returning within the
 * SAME function, with no user-code callback in between -- so these stay libc
 * allocations rather than GC_MALLOC; mixing allocators for memory the caller
 * itself frees would be its own hazard. (Value* staging arrays that span a
 * creme_apply now use GC_MALLOC instead, since creme_apply can longjmp out via
 * call/cc or raise and skip the free.) All this adds over a bare malloc() is a
 * checked, catchable abort on allocation failure instead of a NULL deref. */
static void *xmalloc(size_t n) {
  void *p = malloc(n);
  if (!p) creme_abort("out of memory (requested %zu bytes)", n);
  return p;
}

static void port_buf_grow(Port *p, int extra) {
  /* size_t math + cap: int `p->len + extra` / `p->cap * 2` wrap near 2 GB. */
  size_t need = (size_t)p->len + (size_t)(extra > 0 ? extra : 0);
  if (need > (size_t)p->cap) {
    size_t newcap = p->cap ? (size_t)p->cap * 2 : 64;
    while (newcap < need) newcap *= 2;
    if (newcap > INT_MAX) creme_abort("port buffer too large");
    p->cap = (int)newcap;
    p->buf = GC_REALLOC(p->buf, newcap);
  }
}

static Value bi_make_vector(VM *vm, Value *args, int nargs) {
  (void)vm;
  int64_t n = creme_arg_int(args, nargs, 0, "make-vector");
  if (n < 0 || n > INT_MAX) creme_abort("make-vector: invalid length %lld", (long long)n);
  Value fill = nargs >= 2 ? args[1] : v_bool(0);
  Vector *vec = GC_MALLOC(sizeof(Vector));
  vec->len = (int)n;
  vec->items = creme_alloc_array((size_t)n, sizeof(Value), "make-vector");
  for (int64_t i = 0; i < n; i++) vec->items[i] = fill;
  return v_vector(vec);
}

static Value bi_make_bytevector(VM *vm, Value *args, int nargs) {
  (void)vm;
  int64_t n = creme_arg_int(args, nargs, 0, "make-bytevector");
  if (n < 0 || n > INT_MAX) creme_abort("make-bytevector: invalid length %lld", (long long)n);
  int64_t fill = nargs >= 2 && args[1].tag == T_INT ? args[1].as.i : 0;
  if (fill < 0 || fill > 255) creme_abort("make-bytevector: fill value out of byte range");
  Bytevector *bv = GC_MALLOC(sizeof(Bytevector));
  bv->len = (int)n;
  bv->bytes = creme_alloc_array((size_t)n, 1, "make-bytevector");
  for (int64_t i = 0; i < n; i++) bv->bytes[i] = (unsigned char)fill;
  return v_bytevector(bv);
}

static Value bi_bytevector(VM *vm, Value *args, int nargs) {
  (void)vm;
  Bytevector *bv = GC_MALLOC(sizeof(Bytevector));
  bv->len = nargs;
  bv->bytes = GC_MALLOC((size_t)(nargs ? nargs : 1));
  for (int i = 0; i < nargs; i++) {
    if (args[i].tag != T_INT || args[i].as.i < 0 || args[i].as.i > 255) creme_abort("bytevector: byte out of range");
    bv->bytes[i] = (unsigned char)args[i].as.i;
  }
  return v_bytevector(bv);
}

static Value bi_bytevector_length(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)nargs;
  if (args[0].tag != T_BYTEVECTOR) creme_abort("bytevector-length: not a bytevector");
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
  if (*first < 0 || *last > len || *first > *last) creme_abort("byte range out of bounds");
}

static Value bi_bytevector_copy(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_BYTEVECTOR) creme_abort("bytevector-copy: expected a bytevector");
  Bytevector *src = args[0].as.bv;
  int first, last;
  byte_range_args(args, nargs, 1, src->len, &first, &last);
  return creme_bytevector_value(src->bytes + first, last - first);
}

static Value bi_bytevector_copy_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 3 || args[0].tag != T_BYTEVECTOR || args[1].tag != T_INT || args[2].tag != T_BYTEVECTOR)
    creme_abort("bytevector-copy!: expected (to at from [start [end]])");
  Bytevector *to = args[0].as.bv;
  int64_t at = args[1].as.i; /* keep int64 for the bounds check: (int)at + count overflows */
  Bytevector *from = args[2].as.bv;
  int first, last;
  byte_range_args(args, nargs, 3, from->len, &first, &last);
  int count = last - first;
  if (at < 0 || at + count > to->len) creme_abort("bytevector-copy!: destination too small");
  memmove(to->bytes + (int)at, from->bytes + first, (size_t)count);
  return v_nil();
}

static Value bi_bytevector_append(VM *vm, Value *args, int nargs) {
  (void)vm;
  int64_t total = 0; /* int64: summing lengths in int overflows for ~2 GB aggregate input */
  for (int i = 0; i < nargs; i++) {
    if (args[i].tag != T_BYTEVECTOR) creme_abort("bytevector-append: expected bytevectors");
    total += args[i].as.bv->len;
  }
  if (total > INT_MAX) creme_abort("bytevector-append: result bytevector too large");
  Bytevector *bv = GC_MALLOC(sizeof(Bytevector));
  bv->len = (int)total;
  bv->bytes = creme_alloc_array((size_t)(total ? total : 1), 1, "bytevector-append");
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
  if (nargs < 1 || args[0].tag != T_BYTEVECTOR) creme_abort("utf8->string: expected a bytevector");
  Bytevector *bv = args[0].as.bv;
  int first, last;
  byte_range_args(args, nargs, 1, bv->len, &first, &last);
  int len = last - first;
  return creme_bytes_value((const char *)bv->bytes + first, len);
}

static Value bi_string_to_utf8(VM *vm, Value *args, int nargs) {
  (void)vm;
  int slen;
  const char *s = creme_arg_bytes(args, nargs, 0, "string->utf8", &slen);
  int first, last;
  byte_range_args(args, nargs, 1, slen, &first, &last);
  return creme_bytevector_value((const unsigned char *)s + first, last - first);
}

/* force: mirrors Interpreter#force's own memoization exactly (see
 * src/creme/value/values.cr's SchemePromise) — if `args[0]` isn't itself a
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
    p->cached = creme_apply(vm, p->thunk, NULL, 0);
    p->forced = 1;
  }
  return p->cached;
}

static Value bi_promise_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)nargs;
  return v_bool(args[0].tag == T_PROMISE);
}

/* make-promise: R7RS -- if obj is already a promise, return it
 * unchanged; otherwise return an already-forced promise yielding obj
 * (forcing it never touches `thunk`, so leaving it v_nil() is fine). */
static Value bi_make_promise(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "make-promise");
  if (args[0].tag == T_PROMISE) return args[0];
  Promise *p = GC_MALLOC(sizeof(Promise));
  p->thunk = v_nil();
  p->forced = 1;
  p->cached = args[0];
  return v_promise(p);
}

/* +, -, *, /, and the comparisons as REAL, ordinary global procedures -- never needed
 * for a program compiled by the REAL Crystal analyzer (its own PRIM_OPS
 * table fuses a 2-arg call to one of these names straight into an Add/
 * Sub/etc. op at compile time, see icecreme/README.md's "builtins actually
 * called" note), but the SELF-HOSTED compiler (modules/creme/compiler/
 * compiler.sld) does no such fusion -- it compiles every call, including
 * these, as an ordinary CallGlobal, so anything IT compiles (e.g. a REPL
 * line) needs these names to genuinely exist. Reuse vm.c's own
 * num_add/num_sub/num_mul/num_lt/.../as_double so the semantics
 * (int/float promotion, overflow aborts) are identical to the fused
 * fast-path ops, not a second implementation to keep in sync. */
Value bi_plus(VM *vm, Value *args, int nargs) {
  (void)vm;
  Value acc = v_int(0);
  for (int i = 0; i < nargs; i++) acc = num_add(acc, args[i]);
  return acc;
}

Value bi_minus(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "-");
  if (nargs == 1) return num_sub(v_int(0), args[0]);
  Value acc = args[0];
  for (int i = 1; i < nargs; i++) acc = num_sub(acc, args[i]);
  return acc;
}

Value bi_star(VM *vm, Value *args, int nargs) {
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
  creme_check_min_args(nargs, 1, "/");
  if (nargs == 1) return num_div(v_int(1), args[0]);
  Value acc = args[0];
  for (int i = 1; i < nargs; i++) acc = num_div(acc, args[i]);
  return acc;
}

static Value bi_num_lt(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "<");
  for (int i = 1; i < nargs; i++)
    if (!num_lt(args[i - 1], args[i])) return v_bool(0);
  return v_bool(1);
}

static Value bi_num_gt(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, ">");
  for (int i = 1; i < nargs; i++)
    if (!num_gt(args[i - 1], args[i])) return v_bool(0);
  return v_bool(1);
}

static Value bi_num_le(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "<=");
  for (int i = 1; i < nargs; i++)
    if (!num_le(args[i - 1], args[i])) return v_bool(0);
  return v_bool(1);
}

static Value bi_num_ge(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, ">=");
  for (int i = 1; i < nargs; i++)
    if (!num_ge(args[i - 1], args[i])) return v_bool(0);
  return v_bool(1);
}

static Value bi_num_eq(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "=");
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
/* Fills `out` with an exact mpz_t representation of `v` -- T_INT or
 * T_BIGINT only, aborting for anything else. Shared by quotient/
 * remainder/modulo/floor-quotient/gcd/lcm's own T_BIGINT escape paths
 * below. */
static void value_to_mpz(Value v, mpz_t out, const char *who) {
  if (v.tag == T_INT) {
    mpz_set_si(out, (long)v.as.i);
  } else if (v.tag == T_BIGINT) {
    mpz_set(out, v.as.bigint->z);
  } else {
    creme_abort("%s: expected an integer, got a non-integer value", who);
  }
}

static Value bi_quotient(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 2) creme_abort("quotient: expected two integers");
  if (args[0].tag == T_INT && args[1].tag == T_INT) {
    if (args[1].as.i == 0) creme_abort("quotient: division by zero");
    return v_int(args[0].as.i / args[1].as.i);
  }
  mpz_t a, b, q;
  mpz_inits(a, b, q, NULL);
  value_to_mpz(args[0], a, "quotient");
  value_to_mpz(args[1], b, "quotient");
  if (mpz_sgn(b) == 0) creme_abort("quotient: division by zero");
  mpz_tdiv_q(q, a, b);
  Value result = make_bigint_from_mpz(q);
  mpz_clears(a, b, q, NULL);
  return result;
}

static Value bi_remainder(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 2) creme_abort("remainder: expected two integers");
  if (args[0].tag == T_INT && args[1].tag == T_INT) {
    if (args[1].as.i == 0) creme_abort("remainder: division by zero");
    return v_int(args[0].as.i % args[1].as.i);
  }
  mpz_t a, b, r;
  mpz_inits(a, b, r, NULL);
  value_to_mpz(args[0], a, "remainder");
  value_to_mpz(args[1], b, "remainder");
  if (mpz_sgn(b) == 0) creme_abort("remainder: division by zero");
  mpz_tdiv_r(r, a, b);
  Value result = make_bigint_from_mpz(r);
  mpz_clears(a, b, r, NULL);
  return result;
}

Value bi_modulo(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 2) creme_abort("modulo: expected two integers");
  if (args[0].tag == T_INT && args[1].tag == T_INT) {
    int64_t b = args[1].as.i;
    if (b == 0) creme_abort("modulo: division by zero");
    int64_t r = args[0].as.i % b;
    if (r != 0 && ((r < 0) != (b < 0))) r += b;
    return v_int(r);
  }
  mpz_t a, b, r;
  mpz_inits(a, b, r, NULL);
  value_to_mpz(args[0], a, "modulo");
  value_to_mpz(args[1], b, "modulo");
  if (mpz_sgn(b) == 0) creme_abort("modulo: division by zero");
  mpz_fdiv_r(r, a, b);
  Value result = make_bigint_from_mpz(r);
  mpz_clears(a, b, r, NULL);
  return result;
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
  if (nargs != 2) creme_abort("floor-quotient: expected two integers");
  if (args[0].tag == T_INT && args[1].tag == T_INT) {
    int64_t a = args[0].as.i, b = args[1].as.i;
    if (b == 0) creme_abort("floor-quotient: division by zero");
    int64_t q = a / b, r = a % b;
    if (r != 0 && ((r < 0) != (b < 0))) q -= 1;
    return v_int(q);
  }
  mpz_t a, b, q;
  mpz_inits(a, b, q, NULL);
  value_to_mpz(args[0], a, "floor-quotient");
  value_to_mpz(args[1], b, "floor-quotient");
  if (mpz_sgn(b) == 0) creme_abort("floor-quotient: division by zero");
  mpz_fdiv_q(q, a, b);
  Value result = make_bigint_from_mpz(q);
  mpz_clears(a, b, q, NULL);
  return result;
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

/* Fast int64 path (i64_gcd never overflows for two genuine int64 inputs,
 * EXCEPT negating INT64_MIN, guarded against below) as long as every
 * argument stays a plain T_INT; escalates to mpz_gcd, and stays escalated
 * for the rest of the fold, the moment a T_BIGINT argument (or an
 * INT64_MIN operand) is seen -- mirrors Creme.rat_gcd's own escape design
 * (rational.cr) on the Crystal side. */
static Value bi_gcd(VM *vm, Value *args, int nargs) {
  (void)vm;
  int64_t acc = 0;
  int is_big = 0;
  mpz_t bacc;
  for (int i = 0; i < nargs; i++) {
    Value v = args[i];
    if (!is_big && v.tag == T_INT && v.as.i != INT64_MIN && acc != INT64_MIN) {
      acc = i64_gcd(acc, v.as.i);
      continue;
    }
    if (v.tag != T_INT && v.tag != T_BIGINT) creme_abort("gcd: expected an integer");
    if (!is_big) {
      mpz_init_set_si(bacc, (long)acc);
      is_big = 1;
    }
    mpz_t bv;
    mpz_init(bv);
    value_to_mpz(v, bv, "gcd");
    mpz_gcd(bacc, bacc, bv);
    mpz_clear(bv);
  }
  if (!is_big) return v_int(acc);
  Value result = make_bigint_from_mpz(bacc);
  mpz_clear(bacc);
  return result;
}

static Value bi_lcm(VM *vm, Value *args, int nargs) {
  (void)vm;
  int64_t acc = 1;
  int is_big = 0;
  mpz_t bacc;
  for (int i = 0; i < nargs; i++) {
    Value v = args[i];
    if (v.tag != T_INT && v.tag != T_BIGINT) creme_abort("lcm: expected an integer");
    if (!is_big && v.tag == T_INT && v.as.i != INT64_MIN && acc != INT64_MIN) {
      int64_t vv = v.as.i < 0 ? -v.as.i : v.as.i;
      if (vv == 0) {
        acc = 0;
        continue;
      }
      int64_t g = i64_gcd(acc, vv);
      int64_t r;
      if (!__builtin_mul_overflow(acc / g, vv, &r)) {
        acc = r;
        continue;
      }
      /* the multiply overflowed -- fall through to escalate below,
       * re-deriving this same step in arbitrary precision. */
    }
    if (!is_big) {
      mpz_init_set_si(bacc, (long)acc);
      is_big = 1;
    }
    mpz_t bv, g;
    mpz_inits(bv, g, NULL);
    value_to_mpz(v, bv, "lcm");
    if (mpz_sgn(bv) == 0) {
      mpz_set_si(bacc, 0);
    } else {
      mpz_gcd(g, bacc, bv);
      mpz_divexact(bacc, bacc, g);
      mpz_mul(bacc, bacc, bv);
    }
    mpz_clears(bv, g, NULL);
  }
  if (!is_big) return v_int(acc < 0 ? -acc : acc);
  mpz_abs(bacc, bacc);
  Value result = make_bigint_from_mpz(bacc);
  mpz_clear(bacc);
  return result;
}

/* (expt base exp): an exact-integer (or bigint) base with a non-negative
 * exact-integer exponent stays an exact integer, computed via GMP's own
 * mpz_pow_ui -- no more overflow-abort, this escalates to T_BIGINT the
 * same way num_mul/num_add/num_sub do (make_bigint_from_mpz collapses
 * back to T_INT whenever the result fits). A NEGATIVE exact-integer
 * exponent produces an exact T_RATIONAL (1/base^|exp|) via mpq_inv, which
 * handles the sign correctly regardless of the denominator's own sign --
 * matches native's own expt exactly ((expt 2 -1) is exact 1/2, not
 * inexact 0.5). Everything else falls back to a float pow via as_double. */
static Value bi_expt(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_exact_args(nargs, 2, "expt");
  Value base = args[0], ex = args[1];
  if ((base.tag == T_INT || base.tag == T_BIGINT) && ex.tag == T_INT) {
    mpz_t b;
    mpz_init(b);
    value_to_mpz(base, b, "expt");
    if (ex.as.i >= 0) {
      mpz_t r;
      mpz_init(r);
      /* ex.as.i >= 0 here, and unsigned long is 64-bit on this project's
       * only target (see vm.c's own comment on this same LP64 fact), so
       * this cast is exact for every non-negative int64_t. */
      mpz_pow_ui(r, b, (unsigned long)ex.as.i);
      Value result = make_bigint_from_mpz(r);
      mpz_clears(b, r, NULL);
      return result;
    }
    if (mpz_sgn(b) == 0) {
      mpz_clear(b);
      creme_abort("expt: division by zero (0 raised to a negative power)");
    }
    /* |ex| via mpz_abs (not raw int64_t negation) so exp==INT64_MIN, whose
     * magnitude 2**63 can't be negated in int64_t (UB), is handled exactly
     * like any other exponent. */
    mpz_t exp_abs, denom;
    mpz_inits(exp_abs, denom, NULL);
    mpz_set_si(exp_abs, (long)ex.as.i);
    mpz_abs(exp_abs, exp_abs);
    if (!mpz_fits_ulong_p(exp_abs)) creme_abort("expt: exponent too large");
    mpz_pow_ui(denom, b, mpz_get_ui(exp_abs));
    mpq_t q;
    mpq_init(q);
    mpq_set_z(q, denom);
    mpq_inv(q, q);
    mpq_canonicalize(q);
    Value result = make_rational_from_mpq(q);
    mpq_clear(q);
    mpz_clears(b, exp_abs, denom, NULL);
    return result;
  }
  return v_float(pow(as_double(base, "expt"), as_double(ex, "expt")));
}

static Value bi_exact_integer_sqrt(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "exact-integer-sqrt");
  if (args[0].tag == T_INT) {
    int64_t n = args[0].as.i;
    if (n < 0) creme_abort("exact-integer-sqrt: expected a non-negative integer");
    int64_t root = (int64_t)sqrt((double)n);
    while (root > 0 && root * root > n) root--;
    while ((root + 1) * (root + 1) <= n) root++;
    int64_t rem = n - root * root;
    return make_values2(vm, v_int(root), v_int(rem));
  }
  if (args[0].tag == T_BIGINT) {
    if (mpz_sgn(args[0].as.bigint->z) < 0) creme_abort("exact-integer-sqrt: expected a non-negative integer");
    mpz_t root, rem;
    mpz_inits(root, rem, NULL);
    mpz_sqrtrem(root, rem, args[0].as.bigint->z);
    Value root_v = make_bigint_from_mpz(root);
    Value rem_v = make_bigint_from_mpz(rem);
    mpz_clears(root, rem, NULL);
    return make_values2(vm, root_v, rem_v);
  }
  creme_abort("exact-integer-sqrt: expected a non-negative integer");
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
 * own write-float64! (ICE chunk serialization), so ANY chunk containing
 * a float constant needs this -- not a test-specific gap, a foundational
 * one that surfaced the first time a spec/creme test file with a float
 * literal ran under icecreme's compiler mode. */
static Value bi_flonum_to_bits(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_FLOAT) creme_abort("flonum->bits: expected a float");
  int64_t bits;
  double f = args[0].as.f;
  memcpy(&bits, &f, sizeof(bits));
  return v_int(bits);
}
static Value bi_bits_to_flonum(VM *vm, Value *args, int nargs) {
  (void)vm;
  double f;
  int64_t bits = creme_arg_int(args, nargs, 0, "bits->flonum");
  memcpy(&f, &bits, sizeof(f));
  return v_float(f);
}

/* ---- (scheme inexact)/(creme math): transcendentals -- thin libm
 * wrappers over as_double (already used by abs/magnitude/etc., accepts
 * T_INT/T_RATIONAL/T_FLOAT), same "always returns a float" contract as
 * native's own Math.sin/cos/etc.-based implementation. */
static Value bi_sin(VM *vm, Value *args, int nargs) { (void)vm; return v_float(sin(creme_arg_double(args, nargs, 0, "sin"))); }
static Value bi_cos(VM *vm, Value *args, int nargs) { (void)vm; return v_float(cos(creme_arg_double(args, nargs, 0, "cos"))); }
static Value bi_tan(VM *vm, Value *args, int nargs) { (void)vm; return v_float(tan(creme_arg_double(args, nargs, 0, "tan"))); }
static Value bi_asin(VM *vm, Value *args, int nargs) { (void)vm; return v_float(asin(creme_arg_double(args, nargs, 0, "asin"))); }
static Value bi_acos(VM *vm, Value *args, int nargs) { (void)vm; return v_float(acos(creme_arg_double(args, nargs, 0, "acos"))); }
static Value bi_atan(VM *vm, Value *args, int nargs) { (void)vm; return v_float(atan(creme_arg_double(args, nargs, 0, "atan"))); }
static Value bi_exp(VM *vm, Value *args, int nargs) { (void)vm; return v_float(exp(creme_arg_double(args, nargs, 0, "exp"))); }
static Value bi_log2(VM *vm, Value *args, int nargs) { (void)vm; return v_float(log2(creme_arg_double(args, nargs, 0, "log2"))); }
static Value bi_log10(VM *vm, Value *args, int nargs) { (void)vm; return v_float(log10(creme_arg_double(args, nargs, 0, "log10"))); }
static Value bi_atan2(VM *vm, Value *args, int nargs) { (void)vm; return v_float(atan2(creme_arg_double(args, nargs, 0, "atan2"), creme_arg_double(args, nargs, 1, "atan2"))); }
static Value bi_pow(VM *vm, Value *args, int nargs) { (void)vm; return v_float(pow(creme_arg_double(args, nargs, 0, "pow"), creme_arg_double(args, nargs, 1, "pow"))); }
static Value bi_hypot(VM *vm, Value *args, int nargs) { (void)vm; return v_float(hypot(creme_arg_double(args, nargs, 0, "hypot"), creme_arg_double(args, nargs, 1, "hypot"))); }

/* log's optional 2nd argument is an explicit base, computed as log(x)/
 * log(base) -- matches native's own MathLibrary#log exactly. */
static Value bi_log(VM *vm, Value *args, int nargs) {
  (void)vm;
  double x = log(creme_arg_double(args, nargs, 0, "log"));
  return nargs >= 2 ? v_float(x / log(as_double(args[1], "log"))) : v_float(x);
}

/* (scheme inexact)'s sqrt/nan?/infinite?/finite? -- sqrt has an exact
 * perfect-square fast path ((sqrt 4) is exact 2, not inexact 2.0) ahead
 * of the float fallback, and returns a T_COMPLEX for a negative real
 * (the magnitude's square root goes on the imaginary axis, per R7RS),
 * mirroring native's own sqrt (modules/scheme/inexact.cr) exactly. A
 * genuinely T_COMPLEX argument aborts via as_double itself (same as
 * native's own Creme.as_f64) -- this prototype's sqrt doesn't support
 * complex input either. */
static Value bi_sqrt(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "sqrt");
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
  creme_check_min_args(nargs, 1, "nan?");
  return v_bool(args[0].tag == T_FLOAT && isnan(args[0].as.f));
}

static Value bi_infinite_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "infinite?");
  return v_bool(args[0].tag == T_FLOAT && isinf(args[0].as.f));
}

static Value bi_finite_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "finite?");
  return v_bool(args[0].tag != T_FLOAT || isfinite(args[0].as.f));
}

/* ---- (creme random): random-real/random-integer/random-seed!/
 * random-choice/random-shuffle. A splitmix64 PRNG (a single, process-
 * wide `rng_state`, not per-Interpreter the way native's own
 * interp.random_rng is) -- deliberately NOT bit-for-bit compatible with
 * Crystal's own Random (PCG-based), since nothing in this codebase
 * observes icecreme's random sequence against a real Crystal process (see
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
  int64_t n = creme_arg_int(args, nargs, 0, "random-integer");
  if (n <= 0) creme_abort("random-integer: n must be positive");
  return v_int((int64_t)(rng_next() % (uint64_t)n));
}

static Value bi_random_seed_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  rng_state = (uint64_t)creme_arg_int(args, nargs, 0, "random-seed!");
  return v_nil();
}

static Value bi_random_choice(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "random-choice");
  int n = creme_list_length(args[0]);
  if (n == 0) creme_abort("random-choice: expects a non-empty list");
  int idx = (int)(rng_next() % (uint64_t)n);
  Value cur = args[0];
  for (int i = 0; i < idx; i++) cur = cur.as.pair->cdr;
  return cur.as.pair->car;
}

static Value bi_random_shuffle(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 1, "random-shuffle");
  int n = creme_list_length(args[0]);
  Value *arr = GC_MALLOC(sizeof(Value) * (size_t)(n ? n : 1));
  creme_list_to_values(args[0], arr, n, "random-shuffle");
  /* Fisher-Yates */
  for (int i = n - 1; i > 0; i--) {
    int j = (int)(rng_next() % (uint64_t)(i + 1));
    Value tmp = arr[i];
    arr[i] = arr[j];
    arr[j] = tmp;
  }
  Value result = v_nil();
  for (int i = n - 1; i >= 0; i--) result = creme_cons(vm, arr[i], result);
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
    fwrite(v.as.chars, 1, (size_t)v.aux, out);
    break;
  case T_SYM:
    fwrite(v.as.chars, 1, (size_t)v.aux, out);
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
    fwrite(v.as.record_type->name.as.chars, 1, (size_t)v.as.record_type->name.aux, out);
    fputc('>', out);
    break;
  case T_RECORD: {
    /* Mirrors SchemeRecord#to_display exactly (record.cr): "#<name
     * field=val field=val ...>". */
    RecordType *rt = v.as.record->type;
    fputc('#', out);
    fputc('<', out);
    fwrite(rt->name.as.chars, 1, (size_t)rt->name.aux, out);
    for (int i = 0; i < rt->n_fields; i++) {
      fputc(' ', out);
      fwrite(rt->field_names[i].as.chars, 1, (size_t)rt->field_names[i].aux, out);
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
    fputs(v.aux == BOX_KIND_EOF ? "#<eof>" : "#<native-object>", out);
    break;
  case T_BIGINT:
    mpz_out_str(out, 10, v.as.bigint->z);
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
    creme_abort("display: unsupported value type in this prototype");
  }
}

/* bi_display/bi_newline themselves are defined further down (after the
 * current-output-port indirection/write_bytes_to_port helper they now
 * both need — see that section's own comment for why). */
static Value bi_display(VM *vm, Value *args, int nargs);
static Value bi_newline(VM *vm, Value *args, int nargs);

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
  Port *p = creme_arg_port(args, nargs, 0, "get-output-string");
  if (p->kind != PORT_KIND_OUTPUT_STRING) creme_abort("get-output-string: expected a string output port");
  /* Copies out (matches SchemeStr's own value-semantics — a fresh immutable
   * string each call), even though nothing in this bench mutates the port
   * afterward. GC_MALLOC'd like every other heap value here. */
  return creme_bytes_value(p->buf, p->len);
}

static Value bi_string_length(VM *vm, Value *args, int nargs) {
  (void)vm;
  int len;
  creme_arg_bytes(args, nargs, 0, "string-length", &len);
  return v_int(len);
}

/* Sentinel Ports identifying (current-output-port)/(current-input-port) --
 * write-string/display/write-char/write special-case the output one to
 * write straight to stdout rather than buffering (there's nothing to
 * later get-output-string out of "the real terminal"); read-char/peek-
 * char/read-line special-case the input one to read straight from stdin.
 * Both rely on `kind` being PORT_KIND_STDOUT/PORT_KIND_STDIN respectively
 * (PORT_KIND_STDOUT is enum value 0, so the zero-initialized static
 * struct already has the right kind; PORT_KIND_STDIN needs an explicit
 * initializer since it isn't the zero value). These are just each
 * parameter's own default value, below. */
static Port stdout_port_sentinel;
static Port stdin_port_sentinel = {.kind = PORT_KIND_STDIN};

/* current-output-port/current-input-port are now genuine T_PARAMETER
 * values (vm->current_output_param/vm->current_input_param, `Parameter`
 * per value.h) -- not plain 0-arg builtins the way they used to be --
 * so `parameterize` can genuinely retarget them (this used to abort
 * with "parameterize: expected a parameter object", a documented icecreme
 * gap). Stored as a field on the VM struct itself, one per VM instance,
 * rather than a `_Thread_local` C global the way this used to work:
 * icecreme/vm.h's own VM struct is ALREADY effectively one-VM-per-thread
 * (see creme_new_child_vm's own doc comment -- an actor spawn builds a
 * genuinely separate VM for its own dedicated pthread), so a VM-struct
 * field gives the exact same per-thread independence a `_Thread_local`
 * global did, with no extra machinery -- and, critically, makes the
 * value reachable through the ordinary `vm->globals` global table too
 * (creme_init_current_ports interns it directly, pi/e-style), which a
 * `_Thread_local` C static never could be. creme_new_child_vm calls this
 * again for every freshly spawned VM (giving it its OWN fresh Parameter
 * objects, not ones inherited via its wholesale `globals` memcpy from
 * the parent -- sharing the parent's Parameter would let one actor's
 * with-output-to-file/parameterize redirect a SIBLING's default port,
 * a genuine cross-thread bug, not just wrong scoping).
 *
 * Every port-defaulting builtin below (display/write/write-char/
 * newline/read-line/read-char/peek-char/...) still spells this the
 * same way it always did -- `g_current_output_port`/
 * `g_current_input_port` -- via the two macros just below, which expand
 * to a valid lvalue through whichever `vm` is in scope at each call
 * site (every builtin receives one), so no other call site needed to
 * change at all. */
void creme_init_current_ports(VM *vm) {
  Parameter *out = GC_MALLOC(sizeof(Parameter));
  out->value = v_port(&stdout_port_sentinel);
  out->converter = v_nil();
  out->has_converter = 0;
  vm->current_output_param = out;

  Parameter *in = GC_MALLOC(sizeof(Parameter));
  in->value = v_port(&stdin_port_sentinel);
  in->converter = v_nil();
  in->has_converter = 0;
  vm->current_input_param = in;
}
#define g_current_output_port (vm->current_output_param->value.as.port)
#define g_current_input_port (vm->current_input_param->value.as.port)

/* Shared by display/newline/write/write-char (write-string already had
 * its own, now-redundant copy of this same dispatch inline -- left as
 * is, narrow and unlikely to change). */
static void write_bytes_to_port(Port *p, const char *bytes, size_t len, const char *who) {
  if (p->kind == PORT_KIND_FILTER) {
    p->filter->on_write(p, (const unsigned char *)bytes, (int)len);
    return;
  }
  if (p->kind == PORT_KIND_STDOUT || p->kind == PORT_KIND_OUTPUT_FILE) {
    fwrite(bytes, 1, len, p->kind == PORT_KIND_STDOUT ? stdout : p->file);
    return;
  }
  if (p->kind != PORT_KIND_OUTPUT_STRING) creme_abort("%s: expected an output port", who);
  port_buf_grow(p, (int)len);
  memcpy(p->buf + p->len, bytes, len);
  p->len += (int)len;
}

/* (display obj [port])/(newline [port]) -- port defaults to
 * (current-output-port), i.e. g_current_output_port, same convention
 * write/write-char/write-string already use. Renders through an
 * in-memory stream first (open_memstream, the same trick bi_write/
 * bi_error/bi_raise already use) so the same print_value traversal
 * works for both sinks (a real FILE* for stdout/a file port, or a
 * string port's own byte buffer) without a second, buffer-specific
 * traversal. */
static Value bi_display(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "display");
  if (nargs >= 2 && args[1].tag != T_PORT) creme_abort("display: expected a port");
  Port *p = (nargs >= 2) ? args[1].as.port : g_current_output_port;
  char *buf = NULL;
  size_t size = 0;
  FILE *ms = open_memstream(&buf, &size);
  print_value(ms, args[0]);
  fclose(ms);
  write_bytes_to_port(p, buf, size, "display");
  free(buf);
  return v_nil();
}

static Value bi_newline(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs >= 1 && args[0].tag != T_PORT) creme_abort("newline: expected a port");
  Port *p = (nargs >= 1) ? args[0].as.port : g_current_output_port;
  write_bytes_to_port(p, "\n", 1, "newline");
  return v_nil();
}

static Value bi_write_string(VM *vm, Value *args, int nargs) {
  (void)vm;
  int len;
  const char *s = creme_arg_bytes(args, nargs, 0, "write-string", &len);
  Port *p = creme_arg_port(args, nargs, 1, "write-string");
  if (p->kind == PORT_KIND_FILTER) {
    p->filter->on_write(p, (const unsigned char *)s, len);
    return v_nil();
  }
  if (p->kind == PORT_KIND_STDOUT || p->kind == PORT_KIND_OUTPUT_FILE) {
    fwrite(s, 1, (size_t)len, p->kind == PORT_KIND_STDOUT ? stdout : p->file);
    return v_nil();
  }
  if (p->kind != PORT_KIND_OUTPUT_STRING) creme_abort("write-string: expected an output port");
  port_buf_grow(p, len);
  memcpy(p->buf + p->len, s, (size_t)len);
  p->len += len;
  return v_nil();
}

/* (write-char char [port]) -- port defaults to stdout, same convention
 * as write/write-string. Codepoints are stored/produced byte-wise in
 * this prototype (see string-ref's own comment), so a single byte
 * append/fputc mirrors that scope exactly. */
static Value bi_write_char(VM *vm, Value *args, int nargs) {
  (void)vm;
  int64_t ch = creme_arg_char(args, nargs, 0, "write-char");
  if (nargs >= 2 && args[1].tag != T_PORT) creme_abort("write-char: expected a port");
  Port *p = (nargs >= 2) ? args[1].as.port : g_current_output_port;
  char c = (char)ch;
  write_bytes_to_port(p, &c, 1, "write-char");
  return v_nil();
}

/* ---- input ports: open-input-string, read-char/peek-char/read-line,
 * eof-object[?], port?/input-port?/output-port?, close-port. File ports
 * (open-input-file/open-output-file/call-with-*-file/file-exists?) reuse
 * this same kind-tagged Port -- see the "file ports" section below. */

static Value bi_open_input_string(VM *vm, Value *args, int nargs) {
  (void)vm;
  int len;
  const char *s = creme_arg_bytes(args, nargs, 0, "open-input-string", &len);
  Port *p = GC_MALLOC(sizeof(Port));
  p->kind = PORT_KIND_INPUT_STRING;
  p->len = len;
  p->buf = GC_MALLOC((size_t)(len ? len : 1));
  memcpy(p->buf, s, (size_t)len);
  p->pos = 0;
  return v_port(p);
}

static Value bi_port_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "port?");
  return v_bool(args[0].tag == T_PORT);
}

static int port_is_input(Port *p) { return p->kind == PORT_KIND_INPUT_STRING || p->kind == PORT_KIND_STDIN || p->kind == PORT_KIND_INPUT_FILE || (p->kind == PORT_KIND_FILTER && p->filter_input); }
static int port_is_output(Port *p) { return p->kind == PORT_KIND_OUTPUT_STRING || p->kind == PORT_KIND_STDOUT || p->kind == PORT_KIND_OUTPUT_FILE || (p->kind == PORT_KIND_FILTER && !p->filter_input); }

/* A FILTER input port serves its decoded output from buf/len/pos like an
 * INPUT_STRING port; when that's exhausted, `refill` decodes more (pulling from
 * the wrapped port). The read builtins call this at the buffer-empty check, so
 * their existing buf[pos++] path then serves filter output too. Returns 1 if
 * bytes are now available, 0 at end of stream (or for a non-filter port). */
static int filter_refill(Port *p) {
  return (p->kind == PORT_KIND_FILTER && p->filter && p->filter->refill) ? p->filter->refill(p) : 0;
}

/* Close a port, cascading through a filter stack: a FILTER port flushes its tail
 * to the wrapped port (on_close) and then closes the wrapped port too, so one
 * close-port on the outer finalizes the whole pipeline down to the handle. */
static void port_close(Port *p) {
  if (p->closed) return;
  if (p->kind == PORT_KIND_FILTER) {
    if (p->filter && p->filter->on_close) p->filter->on_close(p);
    p->closed = 1;
    if (p->wrapped) port_close(p->wrapped);
    return;
  }
  if ((p->kind == PORT_KIND_INPUT_FILE || p->kind == PORT_KIND_OUTPUT_FILE) && p->file) fclose(p->file);
  p->closed = 1;
}

/* Flush a port, cascading through a filter stack (emit a block boundary at each
 * filter, then flush the real sink underneath). */
static void port_flush(Port *p) {
  if (p->kind == PORT_KIND_FILTER) {
    if (p->filter && p->filter->on_flush) p->filter->on_flush(p);
    if (p->wrapped) port_flush(p->wrapped);
    return;
  }
  if (p->kind == PORT_KIND_STDOUT) fflush(stdout);
  else if (p->kind == PORT_KIND_OUTPUT_FILE && p->file) fflush(p->file);
}

static Value bi_input_port_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "input-port?");
  return v_bool(args[0].tag == T_PORT && port_is_input(args[0].as.port));
}

static Value bi_output_port_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "output-port?");
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
  creme_check_min_args(nargs, 1, "eof-object?");
  return v_bool(args[0].tag == T_BOX && args[0].aux == BOX_KIND_EOF);
}

static Value bi_close_port(VM *vm, Value *args, int nargs) {
  (void)vm;
  Port *p = creme_arg_port(args, nargs, 0, "close-port");
  port_close(p);
  return v_nil();
}

/* (flush-output-port [port]) -- port defaults to (current-output-port).
 * A no-op for PORT_KIND_OUTPUT_STRING (its buffer is written to
 * synchronously already, nothing to flush); real fflush(3) for
 * PORT_KIND_STDOUT/PORT_KIND_OUTPUT_FILE, the two kinds actually backed
 * by a buffered libc FILE*. */
static Value bi_flush_output_port(VM *vm, Value *args, int nargs) {
  (void)vm;
  Port *p = (nargs >= 1) ? (args[0].tag == T_PORT ? args[0].as.port : NULL) : g_current_output_port;
  if (!p) creme_abort("flush-output-port: expected a port");
  port_flush(p);
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
  char *path = xmalloc((size_t)s.aux + 1);
  memcpy(path, s.as.chars, (size_t)s.aux);
  path[s.aux] = '\0';
  return path;
}

static Value bi_file_exists_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) creme_abort("file-exists?: expected a string");
  char *path = value_str_to_cstr(args[0]);
  int exists = access(path, F_OK) == 0;
  free(path);
  return v_bool(exists);
}

static Value bi_open_input_file(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) creme_abort("open-input-file: expected a string");
  char *path = value_str_to_cstr(args[0]);
  FILE *f = fopen(path, "r");
  if (!f) creme_abort("open-input-file: file not found: %s", path);
  free(path);
  Port *p = GC_MALLOC(sizeof(Port));
  p->kind = PORT_KIND_INPUT_FILE;
  p->file = f;
  return v_port(p);
}

static Value bi_open_output_file(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) creme_abort("open-output-file: expected a string");
  char *path = value_str_to_cstr(args[0]);
  FILE *f = fopen(path, "w");
  if (!f) creme_abort("open-output-file: could not open: %s", path);
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
  creme_check_min_args(nargs, 2, "call-with-input-file");
  int len;
  creme_arg_bytes(args, nargs, 0, "call-with-input-file", &len);
  Value port_val = bi_open_input_file(vm, args, 1);
  Value result = creme_apply(vm, args[1], &port_val, 1);
  Port *p = port_val.as.port;
  if (!p->closed) fclose(p->file);
  p->closed = 1;
  return result;
}

static Value bi_call_with_output_file(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "call-with-output-file");
  int len;
  creme_arg_bytes(args, nargs, 0, "call-with-output-file", &len);
  Value port_val = bi_open_output_file(vm, args, 1);
  Value result = creme_apply(vm, args[1], &port_val, 1);
  Port *p = port_val.as.port;
  if (!p->closed) fclose(p->file);
  p->closed = 1;
  return result;
}

/* open-binary-input-file/open-binary-output-file -- identical to open-
 * input-file/open-output-file except for fopen's own "b" mode flag (a
 * no-op on POSIX, kept for portability/clarity) and Port's `binary` flag
 * (already used elsewhere to pick T_INT/T_BYTEVECTOR over T_CHAR/T_STR
 * for read-u8/write-u8/etc. -- see value.h's own Port doc comment). */
static Value bi_open_binary_input_file(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) creme_abort("open-binary-input-file: expected a string");
  char *path = value_str_to_cstr(args[0]);
  FILE *f = fopen(path, "rb");
  if (!f) creme_abort("open-binary-input-file: file not found: %s", path);
  free(path);
  Port *p = GC_MALLOC(sizeof(Port));
  p->kind = PORT_KIND_INPUT_FILE;
  p->file = f;
  p->binary = 1;
  return v_port(p);
}

static Value bi_open_binary_output_file(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) creme_abort("open-binary-output-file: expected a string");
  char *path = value_str_to_cstr(args[0]);
  FILE *f = fopen(path, "wb");
  if (!f) creme_abort("open-binary-output-file: could not open: %s", path);
  free(path);
  Port *p = GC_MALLOC(sizeof(Port));
  p->kind = PORT_KIND_OUTPUT_FILE;
  p->file = f;
  p->binary = 1;
  return v_port(p);
}

/* with-input-from-file/with-output-to-file -- redirect (current-input-
 * port)/(current-output-port) to a freshly opened file for the extent
 * of one thunk call, restoring the previous port (and closing the file)
 * afterward EVEN IF the thunk escapes via an error/guard/call-cc -- same
 * guarantee dynamic-wind gives its own `after` thunk, and built on
 * exactly the same mechanism (vm->unwind_stack's UNWIND_DYNAMIC_WIND
 * action, see bi_dynamic_wind's own comment for the full explanation of
 * why pushing this BEFORE calling the thunk is what makes an escaping
 * error still run it). The one wrinkle: UNWIND_DYNAMIC_WIND's `after` is
 * a first-class Scheme-callable Value, but a T_BUILTIN carries no
 * captured closure state at all (see value.h) -- so instead of building
 * one dynamically, restoring "whichever port this call redirected"
 * always means "pop the top of this thread-local stack", which the two
 * shared bi_restore_*_port builtins below do; the port-restore stack's
 * own LIFO order always matches vm->unwind_stack's nesting exactly,
 * since every with-input-from-file/with-output-to-file call pushes
 * exactly one entry onto each in lockstep. */
typedef struct {
  Port *prev;
  FILE *to_close;
} PortRestoreFrame;

#define PORT_RESTORE_CAP 64
static _Thread_local PortRestoreFrame g_input_restore_stack[PORT_RESTORE_CAP];
static _Thread_local int g_input_restore_depth = 0;
static _Thread_local PortRestoreFrame g_output_restore_stack[PORT_RESTORE_CAP];
static _Thread_local int g_output_restore_depth = 0;

static Value bi_restore_input_port(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)args;
  (void)nargs;
  if (g_input_restore_depth <= 0) creme_abort("with-input-from-file: internal restore-stack underflow");
  PortRestoreFrame f = g_input_restore_stack[--g_input_restore_depth];
  fclose(f.to_close);
  g_current_input_port = f.prev;
  return v_nil();
}

static Value bi_restore_output_port(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)args;
  (void)nargs;
  if (g_output_restore_depth <= 0) creme_abort("with-output-to-file: internal restore-stack underflow");
  PortRestoreFrame f = g_output_restore_stack[--g_output_restore_depth];
  fclose(f.to_close);
  g_current_output_port = f.prev;
  return v_nil();
}

static Value bi_with_input_from_file(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "with-input-from-file");
  int len;
  creme_arg_bytes(args, nargs, 0, "with-input-from-file", &len);
  Value port_val = bi_open_input_file(vm, args, 1); /* aborts on a missing file, matching native */
  Port *new_port = port_val.as.port;

  if (g_input_restore_depth >= PORT_RESTORE_CAP) creme_abort("with-input-from-file: nesting too deep (%d levels)", PORT_RESTORE_CAP);
  g_input_restore_stack[g_input_restore_depth].prev = g_current_input_port;
  g_input_restore_stack[g_input_restore_depth].to_close = new_port->file;
  g_input_restore_depth++;
  g_current_input_port = new_port;

  if (vm->n_unwind >= CREME_UNWIND_CAP) creme_abort("icecreme: parameterize/dynamic-wind unwind stack full (CREME_UNWIND_CAP=%d)", CREME_UNWIND_CAP);
  UnwindAction *ua = &vm->unwind_stack[vm->n_unwind++];
  ua->kind = UNWIND_DYNAMIC_WIND;
  ua->after = v_builtin(bi_restore_input_port);

  Value result = creme_apply(vm, args[1], NULL, 0);
  vm->n_unwind--;
  bi_restore_input_port(vm, NULL, 0);
  return result;
}

static Value bi_with_output_to_file(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "with-output-to-file");
  int len;
  creme_arg_bytes(args, nargs, 0, "with-output-to-file", &len);
  Value port_val = bi_open_output_file(vm, args, 1);
  Port *new_port = port_val.as.port;

  if (g_output_restore_depth >= PORT_RESTORE_CAP) creme_abort("with-output-to-file: nesting too deep (%d levels)", PORT_RESTORE_CAP);
  g_output_restore_stack[g_output_restore_depth].prev = g_current_output_port;
  g_output_restore_stack[g_output_restore_depth].to_close = new_port->file;
  g_output_restore_depth++;
  g_current_output_port = new_port;

  if (vm->n_unwind >= CREME_UNWIND_CAP) creme_abort("icecreme: parameterize/dynamic-wind unwind stack full (CREME_UNWIND_CAP=%d)", CREME_UNWIND_CAP);
  UnwindAction *ua = &vm->unwind_stack[vm->n_unwind++];
  ua->kind = UNWIND_DYNAMIC_WIND;
  ua->after = v_builtin(bi_restore_output_port);

  Value result = creme_apply(vm, args[1], NULL, 0);
  vm->n_unwind--;
  bi_restore_output_port(vm, NULL, 0);
  return result;
}

/* ---- (creme file)'s FileExtra: whole-file conveniences beyond R7RS's
 * (scheme file) contract -- file-append/file-lines/file-size/
 * current-directory. (file-read/file-write/delete-file already live in
 * bootstrap.c -- see that file's own header comment.) */
static Value bi_file_append(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "file-append");
  if (args[0].tag != T_STR) creme_abort("file-append: expected (string string)");
  int len;
  const char *data = creme_arg_bytes(args, nargs, 1, "file-append", &len);
  char *path = value_str_to_cstr(args[0]);
  FILE *f = fopen(path, "a");
  if (!f) {
    creme_abort("file-append: could not open: %s", path);
  }
  free(path);
  fwrite(data, 1, (size_t)len, f);
  fclose(f);
  return v_nil();
}

static Value bi_file_lines(VM *vm, Value *args, int nargs) {
  if (nargs < 1 || args[0].tag != T_STR) creme_abort("file-lines: expected a string");
  char *path = value_str_to_cstr(args[0]);
  FILE *f = fopen(path, "r");
  if (!f) creme_abort("file-lines: file not found: %s", path);
  free(path);

  Value lines = v_nil();
  Value *collected = NULL;
  int n = 0, cap = 0;
  char *line = NULL;
  size_t linecap = 0;
  ssize_t got;
  while ((got = getline(&line, &linecap, f)) >= 0) {
    if (got > 0 && line[got - 1] == '\n') got--;
    if (n >= cap) {
      cap = cap ? cap * 2 : 16;
      Value *nc = GC_MALLOC(sizeof(Value) * (size_t)cap);
      if (collected) memcpy(nc, collected, sizeof(Value) * (size_t)n);
      collected = nc;
    }
    collected[n++] = creme_bytes_value(line, (int)got);
  }
  free(line);
  fclose(f);
  for (int i = n - 1; i >= 0; i--) lines = creme_cons(vm, collected[i], lines);
  return lines;
}

static Value bi_file_size(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) creme_abort("file-size: expected a string");
  char *path = value_str_to_cstr(args[0]);
  struct stat st;
  int rc = stat(path, &st);
  if (rc != 0) creme_abort("file-size: file not found: %s", path);
  free(path);
  return v_int((int64_t)st.st_size);
}

static Value bi_current_directory(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)args;
  (void)nargs;
  char buf[4096];
  if (!getcwd(buf, sizeof(buf))) creme_abort("current-directory: getcwd failed");
  int len = (int)strlen(buf);
  return creme_bytes_value(buf, len);
}

/* Resolves the (optional, trailing) port argument for read-char/peek-char/
 * read-line -- defaults to (current-input-port), mirroring the native
 * interpreter's own input_port_arg (base/io.cr). */
static Port *input_port_arg(VM *vm, Value *args, int nargs, int port_argidx, const char *who) {
  Port *p = (nargs > port_argidx) ? (args[port_argidx].tag == T_PORT ? args[port_argidx].as.port : NULL) : g_current_input_port;
  if (!p) creme_abort("%s: expected a port", who);
  if (!port_is_input(p)) creme_abort("%s: expected an input port", who);
  if (p->closed) creme_abort("%s: port is closed", who);
  return p;
}

static Value bi_read_char(VM *vm, Value *args, int nargs) {
  Port *p = input_port_arg(vm, args, nargs, 0, "read-char");
  if (p->kind == PORT_KIND_STDIN || p->kind == PORT_KIND_INPUT_FILE) {
    FILE *stream = p->kind == PORT_KIND_STDIN ? stdin : p->file;
    int c = fgetc(stream);
    return c == EOF ? bi_eof_object(vm, NULL, 0) : v_char(c);
  }
  if (p->pos >= p->len && !filter_refill(p)) return bi_eof_object(vm, NULL, 0);
  return v_char((unsigned char)p->buf[p->pos++]);
}

static Value bi_peek_char(VM *vm, Value *args, int nargs) {
  Port *p = input_port_arg(vm, args, nargs, 0, "peek-char");
  if (p->kind == PORT_KIND_STDIN || p->kind == PORT_KIND_INPUT_FILE) {
    FILE *stream = p->kind == PORT_KIND_STDIN ? stdin : p->file;
    int c = fgetc(stream);
    if (c == EOF) return bi_eof_object(vm, NULL, 0);
    ungetc(c, stream);
    return v_char(c);
  }
  if (p->pos >= p->len && !filter_refill(p)) return bi_eof_object(vm, NULL, 0);
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
  if (nargs < 1 || args[0].tag != T_BYTEVECTOR) creme_abort("open-input-bytevector: expected a bytevector");
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
  Port *p = creme_arg_port(args, nargs, 0, "get-output-bytevector");
  if (p->kind != PORT_KIND_OUTPUT_STRING) creme_abort("get-output-bytevector: expected a bytevector output port");
  return creme_bytevector_value((const unsigned char *)p->buf, p->len);
}

static Value bi_binary_port_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "binary-port?");
  return v_bool(args[0].tag == T_PORT && args[0].as.port->binary);
}

static Value bi_textual_port_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "textual-port?");
  return v_bool(args[0].tag == T_PORT && !args[0].as.port->binary);
}

static Value bi_input_port_open_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  Port *p = creme_arg_port(args, nargs, 0, "input-port-open?");
  return v_bool(port_is_input(p) && !p->closed);
}

static Value bi_output_port_open_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  Port *p = creme_arg_port(args, nargs, 0, "output-port-open?");
  return v_bool(port_is_output(p) && !p->closed);
}

static Value bi_read_u8(VM *vm, Value *args, int nargs) {
  Port *p = input_port_arg(vm, args, nargs, 0, "read-u8");
  if (p->kind == PORT_KIND_STDIN || p->kind == PORT_KIND_INPUT_FILE) {
    FILE *stream = p->kind == PORT_KIND_STDIN ? stdin : p->file;
    int c = fgetc(stream);
    return c == EOF ? bi_eof_object(vm, NULL, 0) : v_int(c);
  }
  if (p->pos >= p->len && !filter_refill(p)) return bi_eof_object(vm, NULL, 0);
  return v_int((unsigned char)p->buf[p->pos++]);
}

static Value bi_peek_u8(VM *vm, Value *args, int nargs) {
  Port *p = input_port_arg(vm, args, nargs, 0, "peek-u8");
  if (p->kind == PORT_KIND_STDIN || p->kind == PORT_KIND_INPUT_FILE) {
    FILE *stream = p->kind == PORT_KIND_STDIN ? stdin : p->file;
    int c = fgetc(stream);
    if (c == EOF) return bi_eof_object(vm, NULL, 0);
    ungetc(c, stream);
    return v_int(c);
  }
  if (p->pos >= p->len && !filter_refill(p)) return bi_eof_object(vm, NULL, 0);
  return v_int((unsigned char)p->buf[p->pos]);
}

/* u8-ready? shares char-ready?'s own "always #t" reasoning exactly (see
 * bi_char_ready_p's comment) -- registered as a second name for the same
 * function rather than duplicated below. */

static Value bi_write_u8(VM *vm, Value *args, int nargs) {
  (void)vm;
  int64_t byte = creme_arg_int(args, nargs, 0, "write-u8");
  Port *p = creme_arg_port(args, nargs, 1, "write-u8");
  char c = (char)byte;
  if (p->kind == PORT_KIND_FILTER) {
    p->filter->on_write(p, (const unsigned char *)&c, 1);
    return v_nil();
  }
  if (p->kind == PORT_KIND_STDOUT || p->kind == PORT_KIND_OUTPUT_FILE) {
    fputc((int)(unsigned char)c, p->kind == PORT_KIND_STDOUT ? stdout : p->file);
    return v_nil();
  }
  if (p->kind != PORT_KIND_OUTPUT_STRING) creme_abort("write-u8: expected an output port");
  port_buf_grow(p, 1);
  p->buf[p->len] = c;
  p->len += 1;
  return v_nil();
}

static Value bi_read_bytevector(VM *vm, Value *args, int nargs) {
  (void)vm;
  int n = (int)creme_arg_int(args, nargs, 0, "read-bytevector");
  if (n < 0) creme_abort("read-bytevector: count must be non-negative");
  Port *p = input_port_arg(vm, args, nargs, 1, "read-bytevector");
  Bytevector *bv = GC_MALLOC(sizeof(Bytevector));
  bv->bytes = GC_MALLOC((size_t)(n ? n : 1));
  int read = 0;
  if (p->kind == PORT_KIND_STDIN || p->kind == PORT_KIND_INPUT_FILE) {
    FILE *stream = p->kind == PORT_KIND_STDIN ? stdin : p->file;
    read = (int)fread(bv->bytes, 1, (size_t)n, stream);
  } else {
    /* Loop so a FILTER port refills across multiple decoded blocks until n
     * bytes or EOF; for a plain buffer port refill is a no-op and this reads
     * min(n, available) in one pass, exactly as before. */
    while (read < n) {
      if (p->pos >= p->len && !filter_refill(p)) break;
      int avail = p->len - p->pos;
      int take = (n - read < avail) ? (n - read) : avail;
      memcpy(bv->bytes + read, p->buf + p->pos, (size_t)take);
      p->pos += take;
      read += take;
    }
  }
  if (read == 0 && n > 0) return bi_eof_object(vm, NULL, 0);
  bv->len = read;
  return v_bytevector(bv);
}

static Value bi_read_bytevector_bang(VM *vm, Value *args, int nargs) {
  if (nargs < 1 || args[0].tag != T_BYTEVECTOR) creme_abort("read-bytevector!: expected a bytevector");
  Bytevector *bv = args[0].as.bv;
  Port *p = input_port_arg(vm, args, nargs, 1, "read-bytevector!");
  int first, last;
  byte_range_args(args, nargs, 2, bv->len, &first, &last);
  int want = last - first;
  int read = 0;
  if (p->kind == PORT_KIND_STDIN || p->kind == PORT_KIND_INPUT_FILE) {
    FILE *stream = p->kind == PORT_KIND_STDIN ? stdin : p->file;
    read = (int)fread(bv->bytes + first, 1, (size_t)want, stream);
  } else {
    while (read < want) {
      if (p->pos >= p->len && !filter_refill(p)) break;
      int avail = p->len - p->pos;
      int take = (want - read < avail) ? (want - read) : avail;
      memcpy(bv->bytes + first + read, p->buf + p->pos, (size_t)take);
      p->pos += take;
      read += take;
    }
  }
  if (read == 0 && want > 0) return bi_eof_object(vm, NULL, 0);
  return v_int(read);
}

static Value bi_write_bytevector(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_BYTEVECTOR) creme_abort("write-bytevector: expected a bytevector");
  Bytevector *bv = args[0].as.bv;
  Port *p = creme_arg_port(args, nargs, 1, "write-bytevector");
  int first, last;
  byte_range_args(args, nargs, 2, bv->len, &first, &last);
  int len = last - first;
  if (p->kind == PORT_KIND_FILTER) {
    p->filter->on_write(p, bv->bytes + first, len);
    return v_nil();
  }
  if (p->kind == PORT_KIND_STDOUT || p->kind == PORT_KIND_OUTPUT_FILE) {
    fwrite(bv->bytes + first, 1, (size_t)len, p->kind == PORT_KIND_STDOUT ? stdout : p->file);
    return v_nil();
  }
  if (p->kind != PORT_KIND_OUTPUT_STRING) creme_abort("write-bytevector: expected an output port");
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
  creme_check_min_args(nargs, 2, "call-with-port");
  Port *p = creme_arg_port(args, nargs, 0, "call-with-port");
  Value result = creme_apply(vm, args[1], args, 1);
  port_close(p);
  return result;
}

/* Shared kind-dispatched Port write, exposed via vm.h (creme_port_write_bytes)
 * for a module outside this file (csv.c's streaming writer) to reuse
 * without duplicating the STDOUT/OUTPUT_FILE/OUTPUT_STRING dispatch
 * bi_write_string/bi_write_char/bi_write already do inline. */
void creme_port_write_bytes(Port *p, const char *bytes, int len) {
  if (p->kind == PORT_KIND_FILTER) {
    p->filter->on_write(p, (const unsigned char *)bytes, len);
    return;
  }
  if (p->kind == PORT_KIND_STDOUT || p->kind == PORT_KIND_OUTPUT_FILE) {
    fwrite(bytes, 1, (size_t)len, p->kind == PORT_KIND_STDOUT ? stdout : p->file);
    return;
  }
  if (p->kind != PORT_KIND_OUTPUT_STRING) creme_abort("write: expected an output port");
  port_buf_grow(p, len);
  memcpy(p->buf + p->len, bytes, (size_t)len);
  p->len += len;
}

/* Shared kind-dispatched Port read, exposed via vm.h (creme_port_read_char/
 * creme_port_peek_char) for csv.c's streaming reader to reuse instead of
 * duplicating read-char/peek-char's own STDIN/INPUT_FILE/INPUT_STRING
 * dispatch. Returns -1 at EOF, else a byte 0-255 -- caller-side EOF
 * checks stay simple ints rather than round-tripping through the
 * BOX_KIND_EOF Value the Scheme-visible read-char/peek-char return. */
int creme_port_read_char(Port *p) {
  if (p->kind == PORT_KIND_STDIN || p->kind == PORT_KIND_INPUT_FILE) {
    FILE *stream = p->kind == PORT_KIND_STDIN ? stdin : p->file;
    int c = fgetc(stream);
    return c == EOF ? -1 : c;
  }
  if (p->pos >= p->len && !filter_refill(p)) return -1;
  return (unsigned char)p->buf[p->pos++];
}

int creme_port_peek_char(Port *p) {
  if (p->kind == PORT_KIND_STDIN || p->kind == PORT_KIND_INPUT_FILE) {
    FILE *stream = p->kind == PORT_KIND_STDIN ? stdin : p->file;
    int c = fgetc(stream);
    if (c == EOF) return -1;
    ungetc(c, stream);
    return c;
  }
  if (p->pos >= p->len && !filter_refill(p)) return -1;
  return (unsigned char)p->buf[p->pos];
}

static Value bi_read_line(VM *vm, Value *args, int nargs) {
  Port *p = input_port_arg(vm, args, nargs, 0, "read-line");
  if (p->kind == PORT_KIND_STDIN || p->kind == PORT_KIND_INPUT_FILE) {
    FILE *stream = p->kind == PORT_KIND_STDIN ? stdin : p->file;
    char *line = NULL;
    size_t cap = 0;
    ssize_t got = getline(&line, &cap, stream);
    if (got < 0) { free(line); return bi_eof_object(vm, NULL, 0); }
    if (got > 0 && line[got - 1] == '\n') got--;
    Value result = creme_bytes_value(line, (int)got);
    free(line);
    return result;
  }
  if (p->pos >= p->len && !filter_refill(p)) return bi_eof_object(vm, NULL, 0);
  int start = p->pos;
  while (p->pos < p->len && p->buf[p->pos] != '\n') p->pos++;
  int line_len = p->pos - start;
  Value result = creme_bytes_value(p->buf + start, line_len);
  if (p->pos < p->len) p->pos++; /* consume the newline itself */
  return result;
}

/* (read-string k [port]) -- note the arg order (k first, port second),
 * unlike read-line/read-char's (port only). Mirrors native's own
 * read_string (io.cr) exactly: ALL k characters must be available or
 * this returns an eof-object -- native builds this on Crystal's
 * IO#read_fully?, which fills the whole buffer or fails, rather than
 * R7RS's more literal "up to k, or as many as available" wording;
 * matched here for consistency with native rather than diverging on
 * this edge case (confirmed by direct comparison: native's own
 * `(read-string 10 (open-input-string "hi"))` is `#<eof>`, not "hi"). */
static Value bi_read_string(VM *vm, Value *args, int nargs) {
  int64_t k = creme_arg_int(args, nargs, 0, "read-string");
  if (k < 0) creme_abort("read-string: count must be non-negative");
  Port *p = input_port_arg(vm, args, nargs, 1, "read-string");
  char *buf = GC_MALLOC((size_t)(k ? k : 1));
  int64_t n = 0;
  if (p->kind == PORT_KIND_STDIN || p->kind == PORT_KIND_INPUT_FILE) {
    FILE *stream = p->kind == PORT_KIND_STDIN ? stdin : p->file;
    while (n < k) {
      int c = fgetc(stream);
      if (c == EOF) break;
      buf[n++] = (char)c;
    }
  } else {
    while (n < k) {
      if (p->pos >= p->len && !filter_refill(p)) break;
      while (n < k && p->pos < p->len) buf[n++] = p->buf[p->pos++];
    }
  }
  if (n < k) return bi_eof_object(vm, NULL, 0);
  return v_str(buf, (int)n);
}

/* ===========================================================================
 * (scheme read)'s `read` -- a real R7RS datum parser, absent from this
 * prototype until now. icecreme's ahead-of-time --emit-icecreme mode has no other
 * way to get one: unlike "compiler mode" (raw .scm source through
 * icecreme/icecreme.ice), which defines read/eval/open-input-string-as-
 * datum-reader in Scheme by reusing the self-hosted reader/compiler
 * already loaded there (see icecreme/README.md's "Native builtins" section),
 * an ahead-of-time-compiled chunk has no resident compiler/reader at all
 * to borrow from -- so any library depending on real (scheme read) (e.g.
 * modules/creme/raft-machine.sld's command encode/decode) simply couldn't
 * run under --emit-icecreme before this.
 *
 * Scope: numbers (exact integers, exact rationals via GMP, inexact
 * floats, #b/#o/#d/#x radix prefixes), booleans (#t/#f/#true/#false),
 * chars (#\a, #\space, #\newline, #\tab, #\nul, #\x<hex>), strings (with
 * \n \t \r \\ \" \a \b escapes and \xHH; hex escapes), symbols, proper
 * and dotted lists, vectors #(...), bytevectors #u8(...), the four
 * quote/quasiquote reader macros ('x, `x, ,x, ,@x), and whitespace/
 * comments (; line, #| block, nestable |#, #; datum). Deliberately not
 * in scope: complex number literals, |...|-quoted symbols, and the
 * #<char>-per-code-point exotica R7RS otherwise allows -- none of this
 * project's own icecreme-targeted code needs them, and the self-hosted
 * reader.sld (used by "compiler mode") remains the actual full R7RS
 * reader for anything that does. */


static int read_peek(Port *p) { return p->pos < p->len ? (unsigned char)p->buf[p->pos] : -1; }
static int read_next(Port *p) { return p->pos < p->len ? (unsigned char)p->buf[p->pos++] : -1; }

static int read_is_delim(int c) {
  return c < 0 || c == '(' || c == ')' || c == '"' || c == ';' || c == '\'' || c == '`' || c == ',' ||
         c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '|' || c == '[' || c == ']';
}

static Value read_datum(VM *vm, Port *p);

static void read_skip_ws(VM *vm, Port *p) {
  for (;;) {
    int c = read_peek(p);
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r') { read_next(p); continue; }
    if (c == ';') { while ((c = read_next(p)) >= 0 && c != '\n') {} continue; }
    if (c == '#' && p->pos + 1 < p->len && p->buf[p->pos + 1] == '|') {
      read_next(p); read_next(p);
      int depth = 1;
      while (depth > 0) {
        int d = read_next(p);
        if (d < 0) creme_abort("read: unterminated #| block comment");
        if (d == '#' && read_peek(p) == '|') { read_next(p); depth++; }
        else if (d == '|' && read_peek(p) == '#') { read_next(p); depth--; }
      }
      continue;
    }
    if (c == '#' && p->pos + 1 < p->len && p->buf[p->pos + 1] == ';') {
      read_next(p); read_next(p);
      read_skip_ws(vm, p);
      read_datum(vm, p); /* discard the datum-comment's own datum */
      continue;
    }
    break;
  }
}

static Value read_list(VM *vm, Port *p, int close) {
  read_skip_ws(vm, p);
  int c = read_peek(p);
  if (c == close) { read_next(p); return v_nil(); }
  if (c < 0) creme_abort("read: unterminated list");
  if (c == '.' && p->pos + 1 < p->len && read_is_delim((unsigned char)p->buf[p->pos + 1])) {
    read_next(p);
    Value tail = read_datum(vm, p);
    read_skip_ws(vm, p);
    if (read_peek(p) != close) creme_abort("read: malformed dotted list");
    read_next(p);
    return tail;
  }
  Value head = read_datum(vm, p);
  Value rest = read_list(vm, p, close);
  return creme_cons(vm, head, rest);
}

static Value read_string_literal(Port *p) {
  read_next(p); /* opening quote */
  char *buf = GC_MALLOC(64);
  int cap = 64, len = 0;
  for (;;) {
    int c = read_next(p);
    int d;
    if (c < 0) creme_abort("read: unterminated string literal");
    if (c == '"') break;
    if (c == '\\') {
      int e = read_next(p);
      switch (e) {
        case 'n': c = '\n'; break;
        case 't': c = '\t'; break;
        case 'r': c = '\r'; break;
        case 'a': c = '\a'; break;
        case 'b': c = '\b'; break;
        case '\\': c = '\\'; break;
        case '"': c = '"'; break;
        case 'x': {
          int v = 0;
          while ((d = read_peek(p)) != ';' && d >= 0) {
            read_next(p);
            v = v * 16 + (d >= '0' && d <= '9' ? d - '0' : (tolower(d) - 'a' + 10));
          }
          if (read_peek(p) == ';') read_next(p);
          c = v;
          break;
        }
        case '\n':
          while ((d = read_peek(p)) == ' ' || d == '\t') read_next(p);
          continue;
        default: c = e; break;
      }
    }
    if (len + 1 > cap) { cap *= 2; buf = GC_REALLOC(buf, (size_t)cap); }
    buf[len++] = (char)c;
  }
  return v_str(buf, len);
}

static Value read_char_literal(Port *p) {
  read_next(p); read_next(p); /* consume "#\" */
  char name[32];
  int nlen = 0;
  int first = read_next(p);
  if (first < 0) creme_abort("read: unterminated char literal");
  name[nlen++] = (char)first;
  while (nlen < (int)sizeof(name) - 1 && !read_is_delim(read_peek(p))) name[nlen++] = (char)read_next(p);
  name[nlen] = 0;
  if (nlen == 1) return v_char((unsigned char)name[0]);
  if (strcasecmp(name, "space") == 0) return v_char(' ');
  if (strcasecmp(name, "newline") == 0) return v_char('\n');
  if (strcasecmp(name, "tab") == 0) return v_char('\t');
  if (strcasecmp(name, "return") == 0) return v_char('\r');
  if (strcasecmp(name, "null") == 0 || strcasecmp(name, "nul") == 0) return v_char(0);
  if (strcasecmp(name, "altmode") == 0 || strcasecmp(name, "escape") == 0) return v_char(27);
  if (strcasecmp(name, "backspace") == 0) return v_char(8);
  if (strcasecmp(name, "delete") == 0 || strcasecmp(name, "rubout") == 0) return v_char(127);
  if ((name[0] == 'x' || name[0] == 'X') && nlen > 1) {
    long v = strtol(name + 1, NULL, 16);
    return v_char(v);
  }
  creme_abort("read: unknown char literal #\\%s", name);
}

/* #b/#o/#d/#x-prefixed exact integer, or a plain token starting past
 * the prefix -- shared by read_hash's number-prefix cases. */
static Value read_radix_number(Port *p, int radix) {
  char buf[128];
  int len = 0;
  while (len < (int)sizeof(buf) - 1 && !read_is_delim(read_peek(p))) buf[len++] = (char)read_next(p);
  buf[len] = 0;
  char *endptr;
  long long iv = strtoll(buf, &endptr, radix);
  if (endptr == buf || *endptr != 0) creme_abort("read: malformed #%c number literal '%s'", radix == 16 ? 'x' : radix == 8 ? 'o' : radix == 2 ? 'b' : 'd', buf);
  return v_int(iv);
}

static Value read_hash(VM *vm, Port *p) {
  read_next(p); /* consume '#' */
  int c = read_peek(p);
  if (c == 't') { while (!read_is_delim(read_peek(p))) read_next(p); return v_bool(1); }
  if (c == 'f') { while (!read_is_delim(read_peek(p))) read_next(p); return v_bool(0); }
  if (c == '\\') { p->pos--; return read_char_literal(p); }
  if (c == '(') {
    read_next(p);
    Value list = read_list(vm, p, ')');
    int n = creme_list_length(list);
    Value *items = GC_MALLOC(sizeof(Value) * (size_t)(n ? n : 1));
    creme_list_to_values(list, items, n, "read");
    return creme_vector_from_values(items, n);
  }
  if (c == 'u' && p->pos + 2 < p->len && p->buf[p->pos + 1] == '8' && p->buf[p->pos + 2] == '(') {
    read_next(p); read_next(p); read_next(p);
    Value list = read_list(vm, p, ')');
    int n = 0;
    for (Value it = list; it.tag == T_PAIR; it = it.as.pair->cdr) n++;
    Bytevector *bv = GC_MALLOC(sizeof(Bytevector));
    bv->len = n;
    bv->bytes = GC_MALLOC((size_t)(n ? n : 1));
    Value it = list;
    for (int i = 0; i < n; i++) {
      Pair *pr = it.as.pair;
      if (pr->car.tag != T_INT || pr->car.as.i < 0 || pr->car.as.i > 255) creme_abort("read: bytevector literal element out of byte range");
      bv->bytes[i] = (unsigned char)pr->car.as.i;
      it = pr->cdr;
    }
    return v_bytevector(bv);
  }
  if (c == 'x' || c == 'X') { read_next(p); return read_radix_number(p, 16); }
  if (c == 'o' || c == 'O') { read_next(p); return read_radix_number(p, 8); }
  if (c == 'b' || c == 'B') { read_next(p); return read_radix_number(p, 2); }
  if (c == 'd' || c == 'D') { read_next(p); return read_radix_number(p, 10); }
  creme_abort("read: unsupported '#%c' syntax", c < 0 ? '?' : c);
}

/* A bare (non-#-prefixed) token: a number if it parses as one in its
 * entirety, else a symbol. Mirrors bi_string_to_number's own
 * int-then-float fallback, plus a simple num/den rational case. */
static Value read_token(Port *p) {
  char buf[256];
  int len = 0;
  while (len < (int)sizeof(buf) - 1 && !read_is_delim(read_peek(p))) buf[len++] = (char)read_next(p);
  buf[len] = 0;
  char *endptr;
  long long iv = strtoll(buf, &endptr, 10);
  if (endptr != buf && *endptr == 0) return v_int(iv);
  char *slash = strchr(buf, '/');
  if (slash && slash != buf && *(slash + 1)) {
    char *e1, *e2;
    long long num = strtoll(buf, &e1, 10);
    long long den = strtoll(slash + 1, &e2, 10);
    if (e1 == slash && *e2 == 0 && den != 0) {
      mpq_t q;
      mpq_init(q);
      mpq_set_si(q, num, (unsigned long)(den < 0 ? -den : den));
      if (den < 0) mpq_neg(q, q);
      mpq_canonicalize(q);
      Value result = make_rational_from_mpq(q);
      mpq_clear(q);
      return result;
    }
  }
  double dv = strtod(buf, &endptr);
  if (endptr != buf && *endptr == 0 && len > 0) return v_float(dv);
  return creme_sym_value(buf, len);
}

static Value read_datum(VM *vm, Port *p) {
  read_skip_ws(vm, p);
  int c = read_peek(p);
  if (c < 0) return bi_eof_object(vm, NULL, 0);
  if (c == '(' || c == '[') { read_next(p); return read_list(vm, p, c == '(' ? ')' : ']'); }
  if (c == ')' || c == ']') creme_abort("read: unexpected '%c'", c);
  if (c == '"') return read_string_literal(p);
  if (c == '#') return read_hash(vm, p);
  if (c == '\'') { read_next(p); return creme_list(vm, v_sym("quote", 5), read_datum(vm, p)); }
  if (c == '`') { read_next(p); return creme_list(vm, v_sym("quasiquote", 10), read_datum(vm, p)); }
  if (c == ',') {
    read_next(p);
    if (read_peek(p) == '@') { read_next(p); return creme_list(vm, v_sym("unquote-splicing", 16), read_datum(vm, p)); }
    return creme_list(vm, v_sym("unquote", 7), read_datum(vm, p));
  }
  return read_token(p);
}

static Value bi_read(VM *vm, Value *args, int nargs) {
  Port *p = input_port_arg(vm, args, nargs, 0, "read");
  if (!(p->kind == PORT_KIND_INPUT_STRING)) creme_abort("read: only input-string ports are supported by this icecreme build");
  return read_datum(vm, p);
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

/* Mirrors native's own needs_pipe_escape? (src/creme/value/values.cr:
 * 138-163): a symbol needs |...| escaping if it's empty or contains any
 * character that would otherwise be read back as something else --
 * whitespace, parens/brackets, string/quote/comment syntax, or `|`/`\`
 * themselves (which also need their own backslash-escaping inside the
 * pipes). Only `write` cares about this -- `display`'s print_value
 * always writes a symbol's raw text, since display never needs a
 * re-readable representation. */
static int symbol_needs_pipe_escape(const char *chars, int len) {
  if (len == 0) return 1;
  for (int i = 0; i < len; i++) {
    switch ((unsigned char)chars[i]) {
    case ' ': case '\t': case '\n': case '\r':
    case '(': case ')': case '[': case ']':
    case '"': case ';': case '\'': case '`': case ',':
    case '|': case '\\':
      return 1;
    default:
      break;
    }
  }
  return 0;
}

static void write_symbol_literal(FILE *out, const char *chars, int len) {
  if (!symbol_needs_pipe_escape(chars, len)) {
    fwrite(chars, 1, (size_t)len, out);
    return;
  }
  fputc('|', out);
  for (int i = 0; i < len; i++) {
    unsigned char c = (unsigned char)chars[i];
    if (c == '|' || c == '\\') fputc('\\', out);
    fputc(c, out);
  }
  fputc('|', out);
}

static void write_value(FILE *out, Value v) {
  switch (v.tag) {
  case T_STR:
    write_string_literal(out, v.as.chars, v.aux);
    break;
  case T_SYM:
    write_symbol_literal(out, v.as.chars, v.aux);
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
  creme_check_min_args(nargs, 1, "write");
  if (nargs >= 2 && args[1].tag != T_PORT) creme_abort("write: expected a port");
  char *buf = NULL;
  size_t size = 0;
  FILE *ms = open_memstream(&buf, &size);
  write_value(ms, args[0]);
  fclose(ms);
  Port *p = (nargs >= 2) ? args[1].as.port : g_current_output_port;
  write_bytes_to_port(p, buf, size, "write");
  free(buf);
  return v_nil();
}

/* ---- write-shared: real #n=/#n# datum-label output ----
 * write-shared MUST be genuinely cycle-safe -- naively aliasing it to
 * plain `write` (as write-simple does, see below) would infinite-loop
 * on a circular argument, since write_value's T_PAIR case has no cycle
 * guard at all (unlike creme_equal, which needed the same fix earlier).
 * This does NOT need real datum-label READER support (icecreme/README.md's
 * documented, much larger gap) -- only the writer side, entirely
 * self-contained here.
 *
 * Two passes, standard approach: `share_mark` walks the datum once,
 * counting how many times each distinct pair/vector pointer is
 * reached -- re-entering a pointer already in the table (whether via a
 * genuine cycle mid-traversal, or a separate later reference to the
 * same shared object) stops further descent there, so this terminates
 * on cycles the same way creme_equal's ancestor-tracking does, just with
 * a whole-traversal "seen" set instead of an ancestor-only one (since
 * write-shared cares about ALL sharing, not just cycles). Any pointer
 * with count >= 2 needs a label. `write_value_shared` then walks it
 * again: the first time a labeled pointer is printed, emit "#N=" before
 * its contents and mark it printed; any later encounter (a cycle
 * looping back, or a second reference to shared substructure) emits
 * "#N#" instead of re-descending. */
typedef struct {
  void *ptr;
  int count;
  int label;   /* -1 until first assigned */
  int printed; /* has "#N=" already been emitted for this pointer? */
} ShareEntry;

typedef struct {
  ShareEntry *entries;
  int n, cap;
  int next_label;
} ShareTable;

static void *share_ptr_of(Value v) {
  if (v.tag == T_PAIR) return v.as.pair;
  if (v.tag == T_VECTOR) return v.as.vec;
  return NULL; /* only pairs/vectors can be shared/cyclic in this VM */
}

static ShareEntry *share_lookup(ShareTable *t, void *ptr) {
  for (int i = 0; i < t->n; i++) {
    if (t->entries[i].ptr == ptr) return &t->entries[i];
  }
  return NULL;
}

static void share_mark(ShareTable *t, Value v) {
  void *ptr = share_ptr_of(v);
  if (!ptr) return;
  ShareEntry *e = share_lookup(t, ptr);
  if (e) {
    e->count++; /* already visited at least once -- cycle or shared; don't re-descend */
    return;
  }
  if (t->n >= t->cap) {
    t->cap = t->cap ? t->cap * 2 : 16;
    t->entries = GC_REALLOC(t->entries, sizeof(ShareEntry) * (size_t)t->cap);
  }
  e = &t->entries[t->n++];
  e->ptr = ptr;
  e->count = 1;
  e->label = -1;
  e->printed = 0;
  if (v.tag == T_PAIR) {
    share_mark(t, v.as.pair->car);
    share_mark(t, v.as.pair->cdr);
  } else {
    for (int i = 0; i < v.as.vec->len; i++) share_mark(t, v.as.vec->items[i]);
  }
}

static void write_value_shared(FILE *out, Value v, ShareTable *t) {
  void *ptr = share_ptr_of(v);
  ShareEntry *e = ptr ? share_lookup(t, ptr) : NULL;
  if (e && e->count >= 2) {
    if (e->printed) {
      fprintf(out, "#%d#", e->label);
      return;
    }
    if (e->label < 0) e->label = t->next_label++;
    fprintf(out, "#%d=", e->label);
    e->printed = 1;
  }
  switch (v.tag) {
  case T_PAIR: {
    fputc('(', out);
    write_value_shared(out, v.as.pair->car, t);
    Value cur = v.as.pair->cdr;
    for (;;) {
      if (cur.tag == T_PAIR) {
        ShareEntry *ce = share_lookup(t, cur.as.pair);
        if (ce && ce->count >= 2) {
          /* A labeled node reached mid-spine (a cycle back to an
           * ancestor, or a separately-shared pair) -- print it as a
           * dotted tail via a nested write_value_shared call (which
           * handles both the "#N#" back-reference and "#N=" first-
           * print cases) rather than keep flattening this list. */
          fputs(" . ", out);
          write_value_shared(out, cur, t);
          fputc(')', out);
          return;
        }
        fputc(' ', out);
        write_value_shared(out, cur.as.pair->car, t);
        cur = cur.as.pair->cdr;
        continue;
      }
      if (cur.tag != T_NIL) {
        fputs(" . ", out);
        write_value_shared(out, cur, t);
      }
      fputc(')', out);
      return;
    }
  }
  case T_VECTOR:
    fputs("#(", out);
    for (int i = 0; i < v.as.vec->len; i++) {
      if (i) fputc(' ', out);
      write_value_shared(out, v.as.vec->items[i], t);
    }
    fputc(')', out);
    break;
  default:
    /* Strings/chars/bytevectors/everything else can't be shared in
     * this VM (share_ptr_of only recognizes pairs/vectors), so
     * write_value's own handling for them is already complete. */
    write_value(out, v);
    break;
  }
}

static Value bi_write_shared(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "write-shared");
  if (nargs >= 2 && args[1].tag != T_PORT) creme_abort("write-shared: expected a port");
  ShareTable t = {NULL, 0, 0, 0};
  share_mark(&t, args[0]);
  char *buf = NULL;
  size_t size = 0;
  FILE *ms = open_memstream(&buf, &size);
  write_value_shared(ms, args[0], &t);
  fclose(ms);
  Port *p = (nargs >= 2) ? args[1].as.port : g_current_output_port;
  write_bytes_to_port(p, buf, size, "write-shared");
  free(buf);
  return v_nil();
}

static Value bi_reverse(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 1, "reverse");
  Value result = v_nil();
  Value cur = args[0];
  while (cur.tag == T_PAIR) {
    result = creme_cons(vm, cur.as.pair->car, result);
    cur = cur.as.pair->cdr;
  }
  if (cur.tag != T_NIL) creme_abort("reverse: improper list");
  return result;
}

static Value bi_length(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "length");
  int64_t n = 0;
  Value cur = args[0];
  while (cur.tag == T_PAIR) {
    n++;
    cur = cur.as.pair->cdr;
  }
  if (cur.tag != T_NIL) creme_abort("length: improper list");
  return v_int(n);
}

/* ---- equal? ----
 * creme_eqv (vm.c) already handles every scalar/identity-compared tag;
 * equal? only adds structural recursion for pairs/vectors/bytevectors.
 * Not static: exposed via vm.h so treelist.c's find_index (treelist-
 * member?/treelist-index-of's default equality) can reuse it instead of
 * duplicating the pair/vector recursion. */

/* Tracks (a-pair, b-pair) frames still on the CURRENT recursion path
 * (pushed on entry to a T_PAIR comparison, popped back to the pre-push
 * mark on return) -- not a whole-traversal visited set. If a pair-pair
 * combination reappears while it's still an ancestor of itself, that's
 * a cycle: R7RS only requires equal? to TERMINATE on circular input, so
 * treating an already-in-progress pair as equal (rather than infinitely
 * re-descending into it) is a legal, minimal fix -- creme_equal used to
 * recurse unconditionally here and would stack-overflow on e.g. a list
 * built via set-cdr! into a cycle. */
typedef struct {
  Pair **a_stack;
  Pair **b_stack;
  int n, cap;
} EqualSeen;

/* Returns 0 (and pushes nothing) if this exact (a, b) pair is already an
 * ancestor on the current path; otherwise pushes it and returns 1. */
static int equal_seen_push(EqualSeen *seen, Pair *a, Pair *b) {
  for (int i = 0; i < seen->n; i++) {
    if (seen->a_stack[i] == a && seen->b_stack[i] == b) return 0;
  }
  if (seen->n >= seen->cap) {
    seen->cap = seen->cap ? seen->cap * 2 : 16;
    seen->a_stack = GC_REALLOC(seen->a_stack, sizeof(Pair *) * (size_t)seen->cap);
    seen->b_stack = GC_REALLOC(seen->b_stack, sizeof(Pair *) * (size_t)seen->cap);
  }
  seen->a_stack[seen->n] = a;
  seen->b_stack[seen->n] = b;
  seen->n++;
  return 1;
}

static int creme_equal_rec(Value a, Value b, EqualSeen *seen) {
  if (a.tag != b.tag) return 0;
  switch (a.tag) {
  case T_PAIR: {
    int mark = seen->n;
    if (!equal_seen_push(seen, a.as.pair, b.as.pair)) return 1;
    int ok = creme_equal_rec(a.as.pair->car, b.as.pair->car, seen) && creme_equal_rec(a.as.pair->cdr, b.as.pair->cdr, seen);
    seen->n = mark;
    return ok;
  }
  case T_VECTOR:
    if (a.as.vec->len != b.as.vec->len) return 0;
    for (int i = 0; i < a.as.vec->len; i++) {
      if (!creme_equal_rec(a.as.vec->items[i], b.as.vec->items[i], seen)) return 0;
    }
    return 1;
  case T_BYTEVECTOR:
    return a.as.bv->len == b.as.bv->len && memcmp(a.as.bv->bytes, b.as.bv->bytes, (size_t)a.as.bv->len) == 0;
  default:
    return creme_eqv(a, b);
  }
}

int creme_equal(Value a, Value b) {
  EqualSeen seen = {NULL, NULL, 0, 0};
  return creme_equal_rec(a, b, &seen);
}

/* ---- creme_hash_value ----
 * A hash consistent with creme_equal, for hashtable.c's Verstable-backed
 * hash-table type. Mirrors creme_equal_rec/creme_eqv tag-for-tag: pair/
 * vector/bytevector get the same structural recursion creme_equal_rec
 * does, everything else falls back to the same by-value/by-content/by-
 * identity treatment creme_eqv does. Every branch mixes in the tag itself
 * (fnv1a_u64's tag_salt) so distinct tags never collide. */

static uint64_t hash_combine(uint64_t h, uint64_t x) {
  /* boost::hash_combine's mixing step. */
  return h ^ (x + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2));
}

static uint64_t fnv1a(const void *data, size_t len) {
  const unsigned char *p = (const unsigned char *)data;
  uint64_t h = 14695981039346656037ULL;
  for (size_t i = 0; i < len; i++) {
    h ^= p[i];
    h *= 1099511628211ULL;
  }
  return h;
}

/* Tracks ancestor pairs on the CURRENT recursion path, same cycle-
 * termination technique as EqualSeen above but for a single value (a
 * circular list must still hash to *something* rather than stack-
 * overflow -- R7RS only requires equal?/its hash to terminate, not to
 * distinguish every possible circular shape). */
typedef struct {
  Pair **stack;
  int n, cap;
} HashSeen;

static int hash_seen_push(HashSeen *seen, Pair *p) {
  for (int i = 0; i < seen->n; i++) {
    if (seen->stack[i] == p) return 0;
  }
  if (seen->n >= seen->cap) {
    seen->cap = seen->cap ? seen->cap * 2 : 16;
    seen->stack = GC_REALLOC(seen->stack, sizeof(Pair *) * (size_t)seen->cap);
  }
  seen->stack[seen->n++] = p;
  return 1;
}

static uint64_t creme_hash_value_rec(Value v, HashSeen *seen) {
  uint64_t tag_salt = ((uint64_t)v.tag + 1) * 0x2545f4914f6cdd1dULL;
  switch (v.tag) {
  case T_NIL:
  case T_BOOL:
    return tag_salt ^ (uint64_t)(v.tag == T_BOOL ? (v.as.b ? 1u : 0u) : 0u);
  case T_INT:
  case T_CHAR:
    return tag_salt ^ (uint64_t)v.as.i;
  case T_FLOAT: {
    uint64_t bits;
    memcpy(&bits, &v.as.f, sizeof(bits));
    return tag_salt ^ bits;
  }
  case T_STR:
  case T_SYM:
    return tag_salt ^ fnv1a(v.as.chars, (size_t)v.aux);
  case T_PAIR: {
    int mark = seen->n;
    if (!hash_seen_push(seen, v.as.pair)) return tag_salt; /* cycle: terminate */
    uint64_t h = hash_combine(creme_hash_value_rec(v.as.pair->car, seen), creme_hash_value_rec(v.as.pair->cdr, seen));
    seen->n = mark;
    return tag_salt ^ h;
  }
  case T_VECTOR: {
    uint64_t h = (uint64_t)v.as.vec->len;
    for (int i = 0; i < v.as.vec->len; i++) h = hash_combine(h, creme_hash_value_rec(v.as.vec->items[i], seen));
    return tag_salt ^ h;
  }
  case T_BYTEVECTOR:
    return tag_salt ^ fnv1a(v.as.bv->bytes, (size_t)v.as.bv->len);
  case T_BIGINT: {
    /* Same GMP-allocated-string-then-fnv1a approach as T_RATIONAL below,
     * for the same reason: hashes exactly the state creme_eqv's own
     * T_BIGINT comparison (mpz_cmp) compares. */
    char *z_str = mpz_get_str(NULL, 10, v.as.bigint->z);
    return tag_salt ^ fnv1a(z_str, strlen(z_str));
  }
  case T_RATIONAL: {
    /* Hash the canonicalized numerator/denominator's decimal digits --
     * exactly the state mpq_equal (creme_eqv's own T_RATIONAL comparison)
     * compares. mpz_get_str's returned buffer is GMP-allocated, which
     * main.c redirects to GC_MALLOC/GC_REALLOC with a no-op free (see
     * value.h's own Rational doc comment) -- no explicit free needed,
     * same as bigdecimal.c's bd_to_string. */
    char *n_str = mpz_get_str(NULL, 10, mpq_numref(v.as.rational->q));
    char *d_str = mpz_get_str(NULL, 10, mpq_denref(v.as.rational->q));
    return tag_salt ^ hash_combine(fnv1a(n_str, strlen(n_str)), fnv1a(d_str, strlen(d_str)));
  }
  case T_COMPLEX:
    return tag_salt ^ hash_combine(creme_hash_value_rec(v.as.cplx->real, seen), creme_hash_value_rec(v.as.cplx->imag, seen));
  case T_BUILTIN:
    /* A function pointer, not an object pointer -- kept separate from the
     * generic `as.ptr` default branch below, since punning a function
     * pointer through `as.ptr` isn't guaranteed portable. */
    return tag_salt ^ (uint64_t)(uintptr_t)v.as.builtin;
  default:
    /* Every remaining identity type (T_PROMISE, T_VALUES, T_PORT,
     * T_CLOSURE, T_CASE_CLOSURE, T_RECORD_TYPE, T_RECORD,
     * T_RECORD_CALLABLE, T_PARAMETER, T_BOX, T_CONTINUATION, T_MACRO) --
     * `as.ptr` reads the same bits as whichever object-pointer member is
     * actually set, same as creme_eqv's own by-identity comparisons. */
    return tag_salt ^ (uint64_t)(uintptr_t)v.as.ptr;
  }
}

uint64_t creme_hash_value(Value v) {
  HashSeen seen = {NULL, 0, 0};
  return creme_hash_value_rec(v, &seen);
}

/* ---- predicates / eq-family (also registered as ordinary procedures for
 * higher-order use, e.g. (map pair? lst) — most of these are normally
 * fused into their own op by the compiler, but a bare reference to the
 * name as a value still needs a real global binding). ---- */
static Value bi_not(VM *vm, Value *args, int nargs) { (void)vm; creme_check_min_args(nargs, 1, "not"); return v_bool(v_falsy(args[0])); }
static Value bi_pair_p(VM *vm, Value *args, int nargs) { (void)vm; creme_check_min_args(nargs, 1, "pair?"); return v_bool(args[0].tag == T_PAIR); }
static Value bi_null_p(VM *vm, Value *args, int nargs) { (void)vm; creme_check_min_args(nargs, 1, "null?"); return v_bool(args[0].tag == T_NIL); }
/* Walks cdr's until a non-pair; #t iff that's T_NIL -- mirrors the real
 * interpreter's own Creme.proper_list? (helpers.cr) exactly, including
 * NOT being cycle-safe (a genuinely circular list would infinite-loop
 * here too, same as there -- a known, already-accepted simplification in
 * the reference implementation this isn't introducing anything new). */
/* Floyd's tortoise-and-hare: R7RS requires list? to return #f -- not
 * hang -- on a genuinely circular list (now reachable via a real datum-
 * label literal, or set-cdr! at runtime), which a plain single-pointer
 * cdr-walk can't do by itself. `fast` advances two cdrs per iteration,
 * `slow` one; if they're ever the exact same pair again, `fast` has
 * lapped `slow` around a cycle. Mirrors src/creme/helpers.cr's own
 * proper_list? fix exactly. */
static Value bi_list_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "list?");
  Value slow = args[0];
  Value fast = args[0];
  for (;;) {
    if (fast.tag == T_NIL) return v_bool(1);
    if (fast.tag != T_PAIR) return v_bool(0);
    fast = fast.as.pair->cdr;
    if (fast.tag == T_NIL) return v_bool(1);
    if (fast.tag != T_PAIR) return v_bool(0);
    fast = fast.as.pair->cdr;
    slow = slow.as.pair->cdr;
    if (fast.tag == T_PAIR && slow.tag == T_PAIR && fast.as.pair == slow.as.pair) return v_bool(0);
  }
}
static Value bi_boolean_p(VM *vm, Value *args, int nargs) { (void)vm; creme_check_min_args(nargs, 1, "boolean?"); return v_bool(args[0].tag == T_BOOL); }
static Value bi_symbol_p(VM *vm, Value *args, int nargs) { (void)vm; creme_check_min_args(nargs, 1, "symbol?"); return v_bool(args[0].tag == T_SYM); }
static Value bi_string_p(VM *vm, Value *args, int nargs) { (void)vm; creme_check_min_args(nargs, 1, "string?"); return v_bool(args[0].tag == T_STR); }
static Value bi_vector_p(VM *vm, Value *args, int nargs) { (void)vm; creme_check_min_args(nargs, 1, "vector?"); return v_bool(args[0].tag == T_VECTOR); }

/* vector-ref/-set!/-length, string-ref/-set!, bytevector-u8-ref/-set! as
 * REAL global procedures -- same story as +/-/cadr/etc. above: a program
 * the real analyzer compiles never needs these (its PRIM_OPS table fuses
 * a call site straight into VecRef/VecSet/StrRef/etc.), but the self-
 * hosted compiler does no such fusion, so anything it compiles needs
 * these to genuinely exist. Semantics mirror the fused ops' own bounds
 * checks exactly (vm.c's OP_VECREF/OP_VECSET/etc.). */
static Value bi_vector_ref(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 2 || args[0].tag != T_VECTOR || args[1].tag != T_INT) creme_abort("vector-ref: expected (vector index)");
  int64_t idx = args[1].as.i; /* compare in int64: (int)idx would wrap a >2^31 index in-bounds */
  if (idx < 0 || idx >= args[0].as.vec->len) creme_abort("vector-ref: index %lld out of range", (long long)idx);
  return args[0].as.vec->items[idx];
}

static Value bi_vector_set(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 3 || args[0].tag != T_VECTOR || args[1].tag != T_INT) creme_abort("vector-set!: expected (vector index value)");
  int64_t idx = args[1].as.i; /* compare in int64: (int)idx would wrap a >2^31 index in-bounds */
  if (idx < 0 || idx >= args[0].as.vec->len) creme_abort("vector-set!: index %lld out of range", (long long)idx);
  args[0].as.vec->items[idx] = args[2];
  return v_nil();
}

static Value bi_vector_length(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 1 || args[0].tag != T_VECTOR) creme_abort("vector-length: expected a vector");
  return v_int(args[0].as.vec->len);
}

/* Shared by vector-copy/-copy!/-fill! below for their optional (start end)
 * args -- mirrors src/creme/modules/scheme/base/vectors.cr's own
 * seq_range_args (defaults: start 0, end len). */
static void vector_range_args(int len, Value *args, int nargs, int start_idx, int *first, int *last) {
  *first = (nargs > start_idx && args[start_idx].tag == T_INT) ? (int)args[start_idx].as.i : 0;
  *last = (nargs > start_idx + 1 && args[start_idx + 1].tag == T_INT) ? (int)args[start_idx + 1].as.i : len;
  if (*first < 0 || *last > len || *first > *last) creme_abort("vector: start/end out of range");
}

static Value bi_vector_copy(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_VECTOR) creme_abort("vector-copy: expected a vector");
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
    creme_abort("vector-copy!: expected (to at from ...)");
  Vector *to = args[0].as.vec;
  int64_t at64 = args[1].as.i; /* keep int64 for the bounds check: (int)at + n overflows */
  Vector *from = args[2].as.vec;
  int first, last;
  vector_range_args(from->len, args, nargs, 3, &first, &last);
  int n = last - first;
  if (at64 < 0 || at64 + n > to->len) creme_abort("vector-copy!: destination range out of bounds");
  int at = (int)at64; /* safe: at64 <= to->len (an int) here */
  if (to == from && at > first) {
    for (int i = n - 1; i >= 0; i--) to->items[at + i] = from->items[first + i];
  } else {
    for (int i = 0; i < n; i++) to->items[at + i] = from->items[first + i];
  }
  return v_nil();
}

static Value bi_vector_fill(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2 || args[0].tag != T_VECTOR) creme_abort("vector-fill!: expected a vector and a fill value");
  Vector *vec = args[0].as.vec;
  Value fill = args[1];
  int first, last;
  vector_range_args(vec->len, args, nargs, 2, &first, &last);
  for (int i = first; i < last; i++) vec->items[i] = fill;
  return v_nil();
}

static Value bi_vector_append(VM *vm, Value *args, int nargs) {
  (void)vm;
  int64_t total = 0; /* int64: summing lengths in int overflows for ~2 GB aggregate input */
  for (int i = 0; i < nargs; i++) {
    if (args[i].tag != T_VECTOR) creme_abort("vector-append: expected a vector");
    total += args[i].as.vec->len;
  }
  if (total > INT_MAX) creme_abort("vector-append: result vector too large");
  Vector *vec = GC_MALLOC(sizeof(Vector));
  vec->len = (int)total;
  vec->items = creme_alloc_array((size_t)(total ? total : 1), sizeof(Value), "vector-append");
  int pos = 0;
  for (int i = 0; i < nargs; i++) {
    Vector *src = args[i].as.vec;
    for (int j = 0; j < src->len; j++) vec->items[pos++] = src->items[j];
  }
  return v_vector(vec);
}

static Value bi_string_ref(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 2 || args[0].tag != T_STR || args[1].tag != T_INT) creme_abort("string-ref: expected (string index)");
  int64_t idx = args[1].as.i; /* compare in int64: (int)idx would wrap a >2^31 index in-bounds */
  if (idx < 0 || idx >= args[0].aux) creme_abort("string-ref: index %lld out of range", (long long)idx);
  return v_char((unsigned char)args[0].as.chars[idx]);
}

static Value bi_string_set(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 3 || args[0].tag != T_STR || args[1].tag != T_INT || args[2].tag != T_CHAR) creme_abort("string-set!: expected (string index char)");
  int64_t idx = args[1].as.i; /* compare in int64: (int)idx would wrap a >2^31 index in-bounds */
  if (idx < 0 || idx >= args[0].aux) creme_abort("string-set!: index %lld out of range", (long long)idx);
  ((char *)args[0].as.chars)[idx] = (char)args[2].as.i;
  return v_nil();
}

static Value bi_bytevector_u8_ref(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 2 || args[0].tag != T_BYTEVECTOR || args[1].tag != T_INT) creme_abort("bytevector-u8-ref: expected (bytevector index)");
  int64_t idx = args[1].as.i; /* compare in int64: (int)idx would wrap a >2^31 index in-bounds */
  if (idx < 0 || idx >= args[0].as.bv->len) creme_abort("bytevector-u8-ref: index %lld out of range", (long long)idx);
  return v_int(args[0].as.bv->bytes[idx]);
}

static Value bi_bytevector_u8_set(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 3 || args[0].tag != T_BYTEVECTOR || args[1].tag != T_INT || args[2].tag != T_INT) creme_abort("bytevector-u8-set!: expected (bytevector index byte)");
  int64_t idx = args[1].as.i; /* compare in int64: (int)idx would wrap a >2^31 index in-bounds */
  if (idx < 0 || idx >= args[0].as.bv->len) creme_abort("bytevector-u8-set!: index %lld out of range", (long long)idx);
  if (args[2].as.i < 0 || args[2].as.i > 255) creme_abort("bytevector-u8-set!: byte out of range");
  args[0].as.bv->bytes[idx] = (unsigned char)args[2].as.i;
  return v_nil();
}
static Value bi_char_p(VM *vm, Value *args, int nargs) { (void)vm; creme_check_min_args(nargs, 1, "char?"); return v_bool(args[0].tag == T_CHAR); }
/* Mirrors the real interpreter's own procedure? exactly (predicates.cr):
 * deliberately narrow -- Builtin/BytecodeClosure/BytecodeCaseClosure
 * (T_RECORD_CALLABLE counts because RecordAccessor/RecordMutator/ctor/
 * pred are real Builtin SUBCLASSES there), but NOT SchemeParameter
 * (T_PARAMETER) -- a parameter is callable via apply's generic dispatch
 * without being procedure?-true. */
static Value bi_procedure_p(VM *vm, Value *args, int nargs) { (void)vm; creme_check_min_args(nargs, 1, "procedure?"); return v_bool(args[0].tag == T_CLOSURE || args[0].tag == T_CASE_CLOSURE || args[0].tag == T_RECORD_CALLABLE || args[0].tag == T_BUILTIN || args[0].tag == T_CONTINUATION); }
static Value bi_number_p(VM *vm, Value *args, int nargs) { (void)vm; creme_check_min_args(nargs, 1, "number?"); return v_bool(args[0].tag == T_INT || args[0].tag == T_BIGINT || args[0].tag == T_FLOAT || args[0].tag == T_RATIONAL || args[0].tag == T_COMPLEX); }
/* real? is every number EXCEPT a genuine T_COMPLEX -- mirrors real?
 * (predicates.cr) exactly: number?(v) && !v.is_a?(SchemeComplex). */
static Value bi_real_p(VM *vm, Value *args, int nargs) { (void)vm; creme_check_min_args(nargs, 1, "real?"); return v_bool(args[0].tag == T_INT || args[0].tag == T_BIGINT || args[0].tag == T_FLOAT || args[0].tag == T_RATIONAL); }
/* complex? is literally an alias for number? -- every number is complex
 * per R7RS (mirrors complex.cr's own complex_p exactly, "true for any
 * number, real or complex"). */
static Value bi_complex_p(VM *vm, Value *args, int nargs) { return bi_number_p(vm, args, nargs); }
static Value bi_integer_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "integer?");
  if (args[0].tag == T_INT || args[0].tag == T_BIGINT) return v_bool(1);
  if (args[0].tag == T_FLOAT) return v_bool(args[0].as.f == floor(args[0].as.f));
  /* T_RATIONAL is never whole by construction (make_rational_from_mpq
   * collapses den==1 to T_INT/T_BIGINT before a T_RATIONAL Value ever
   * exists), so always false here -- mirrors integer? (predicates.cr)
   * exactly. */
  return v_bool(0);
}
/* exact? is int/bigint/rational, matching Creme.exact? exactly
 * (helpers.cr); complex is neither exact? nor inexact? here, same gap
 * native itself has (see complex.cr's own header comment on this not
 * being special-cased) -- not something this port is trying to fix. */
static Value bi_exact_p(VM *vm, Value *args, int nargs) { (void)vm; creme_check_min_args(nargs, 1, "exact?"); return v_bool(args[0].tag == T_INT || args[0].tag == T_BIGINT || args[0].tag == T_RATIONAL); }
static Value bi_inexact_p(VM *vm, Value *args, int nargs) { (void)vm; creme_check_min_args(nargs, 1, "inexact?"); return v_bool(args[0].tag == T_FLOAT); }
static Value bi_exact_integer_p(VM *vm, Value *args, int nargs) { (void)vm; creme_check_min_args(nargs, 1, "exact-integer?"); return v_bool(args[0].tag == T_INT || args[0].tag == T_BIGINT); }
/* rational? is exact (int/bigint/rational) OR a finite float -- mirrors
 * rational? (predicates.cr) exactly. Needed by modules/creme/bytecode.
 * sld's own write-datum! (ICE chunk serialization) to detect a rational
 * constant, so this isn't just a nicety -- without it, compiling any
 * chunk containing a rational constant aborts with "unbound variable:
 * rational?" under icecreme specifically (the self-hosted compiler's own
 * compile-time-constant path always goes through this). */
static Value bi_rational_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "rational?");
  if (args[0].tag == T_INT || args[0].tag == T_BIGINT || args[0].tag == T_RATIONAL) return v_bool(1);
  if (args[0].tag == T_FLOAT) return v_bool(isfinite(args[0].as.f));
  return v_bool(0);
}
/* numerator/denominator -- int/bigint/rational only (matches native's own
 * int/rational cases exactly, now extended to bigint the same way native's
 * SchemeInt.make widening did); a float argument would need native's own
 * round-trip-through-to_exact conversion, not needed by anything in this
 * project's own icecreme test surface. */
static Value bi_numerator(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "numerator");
  if (args[0].tag == T_INT || args[0].tag == T_BIGINT) return args[0];
  if (args[0].tag == T_RATIONAL) return make_bigint_from_mpz(mpq_numref(args[0].as.rational->q));
  creme_abort("numerator: expected an exact rational or integer");
}
static Value bi_denominator(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "denominator");
  if (args[0].tag == T_INT || args[0].tag == T_BIGINT) return v_int(1);
  if (args[0].tag == T_RATIONAL) return make_bigint_from_mpz(mpq_denref(args[0].as.rational->q));
  creme_abort("denominator: expected an exact rational or integer");
}
static Value bi_eq_p(VM *vm, Value *args, int nargs) { (void)vm; creme_check_min_args(nargs, 2, "eq?"); return v_bool(creme_eqv(args[0], args[1])); }
static Value bi_eqv_p(VM *vm, Value *args, int nargs) { (void)vm; creme_check_min_args(nargs, 2, "eqv?"); return v_bool(creme_eqv(args[0], args[1])); }
static Value bi_equal_p(VM *vm, Value *args, int nargs) { (void)vm; creme_check_min_args(nargs, 2, "equal?"); return v_bool(creme_equal(args[0], args[1])); }

/* ---- numeric predicates / conversions ---- */
/* zero?/positive?/negative?/abs all extend to T_RATIONAL below (mpq_sgn/
 * a fresh mpq_t with its numerator negated) -- floor/ceiling/round/
 * truncate of a rational used to be cut here too; see bi_floor/
 * bi_ceiling/bi_round/bi_truncate below for their own T_RATIONAL
 * handling. abs/zero?/positive?/negative? of a T_COMPLEX deliberately
 * stay unimplemented here, matching the native Crystal interpreter's own
 * behavior exactly (src/creme/modules/scheme/base/arithmetic.cr's abs
 * and base/predicates.cr's zero?/positive?/negative? don't accept a
 * complex value either -- (scheme complex)'s magnitude has its own
 * separate complex-aware sqrt(re^2+im^2) logic instead) -- this is
 * parity with native, not a remaining gap. */
static Value bi_zero_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "zero?");
  if (args[0].tag == T_INT) return v_bool(args[0].as.i == 0);
  if (args[0].tag == T_FLOAT) return v_bool(args[0].as.f == 0.0);
  if (args[0].tag == T_BIGINT) return v_bool(0); /* never zero, see value.h */
  if (args[0].tag == T_RATIONAL) return v_bool(0); /* never zero, see value.h */
  creme_abort("zero?: not a number");
}
static Value bi_positive_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "positive?");
  if (args[0].tag == T_INT) return v_bool(args[0].as.i > 0);
  if (args[0].tag == T_FLOAT) return v_bool(args[0].as.f > 0.0);
  if (args[0].tag == T_BIGINT) return v_bool(mpz_sgn(args[0].as.bigint->z) > 0);
  if (args[0].tag == T_RATIONAL) return v_bool(mpq_sgn(args[0].as.rational->q) > 0);
  creme_abort("positive?: not a number");
}
static Value bi_negative_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "negative?");
  if (args[0].tag == T_INT) return v_bool(args[0].as.i < 0);
  if (args[0].tag == T_FLOAT) return v_bool(args[0].as.f < 0.0);
  if (args[0].tag == T_BIGINT) return v_bool(mpz_sgn(args[0].as.bigint->z) < 0);
  if (args[0].tag == T_RATIONAL) return v_bool(mpq_sgn(args[0].as.rational->q) < 0);
  creme_abort("negative?: not a number");
}
static Value bi_odd_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "odd?");
  if (args[0].tag == T_BIGINT) return v_bool(mpz_odd_p(args[0].as.bigint->z));
  return v_bool(creme_arg_int(args, nargs, 0, "odd?") % 2 != 0);
}
static Value bi_even_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "even?");
  if (args[0].tag == T_BIGINT) return v_bool(mpz_even_p(args[0].as.bigint->z));
  return v_bool(creme_arg_int(args, nargs, 0, "even?") % 2 == 0);
}
/* (square z) is equivalent to (* z z) -- reuse num_mul so it promotes
 * through the same int/rational/float/complex tower `*` itself does,
 * rather than re-deriving a narrower version here. */
static Value bi_square(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "square");
  return num_mul(args[0], args[0]);
}
static Value bi_abs(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "abs");
  if (args[0].tag == T_INT) {
    /* INT64_MIN's own magnitude (2**63) doesn't fit back in int64_t --
     * negating it directly is signed-overflow UB, so escalate through
     * mpz instead of negating in place, mirroring rat_abs (rational.cr). */
    if (args[0].as.i == INT64_MIN) {
      mpz_t z;
      mpz_init_set_si(z, (long)args[0].as.i);
      mpz_neg(z, z);
      Value result = make_bigint_from_mpz(z);
      mpz_clear(z);
      return result;
    }
    return v_int(args[0].as.i < 0 ? -args[0].as.i : args[0].as.i);
  }
  if (args[0].tag == T_FLOAT) return v_float(fabs(args[0].as.f));
  if (args[0].tag == T_BIGINT) {
    if (mpz_sgn(args[0].as.bigint->z) >= 0) return args[0];
    mpz_t z;
    mpz_init(z);
    mpz_neg(z, args[0].as.bigint->z);
    Value result = make_bigint_from_mpz(z);
    mpz_clear(z);
    return result;
  }
  if (args[0].tag == T_RATIONAL) {
    if (mpq_sgn(args[0].as.rational->q) >= 0) return args[0];
    mpq_t q;
    mpq_init(q);
    mpq_neg(q, args[0].as.rational->q);
    Value result = make_rational_from_mpq(q);
    mpq_clear(q);
    return result;
  }
  creme_abort("abs: not a number");
}
static Value bi_min(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "min");
  Value m = args[0];
  for (int i = 1; i < nargs; i++) if (num_lt(args[i], m)) m = args[i];
  return m;
}
static Value bi_max(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "max");
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
  (void)who;
  return make_bigint_from_mpz(z);
}

static Value bi_round(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "round");
  if (args[0].tag == T_INT || args[0].tag == T_BIGINT) return args[0];
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
  creme_abort("round: not a number");
}
static Value bi_floor(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "floor");
  if (args[0].tag == T_INT || args[0].tag == T_BIGINT) return args[0];
  if (args[0].tag == T_FLOAT) return v_float(floor(args[0].as.f));
  if (args[0].tag == T_RATIONAL) {
    mpz_t z;
    mpz_init(z);
    mpz_fdiv_q(z, mpq_numref(args[0].as.rational->q), mpq_denref(args[0].as.rational->q));
    Value result = mpz_to_int_value(z, "floor");
    mpz_clear(z);
    return result;
  }
  creme_abort("floor: not a number");
}
static Value bi_ceiling(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "ceiling");
  if (args[0].tag == T_INT || args[0].tag == T_BIGINT) return args[0];
  if (args[0].tag == T_FLOAT) return v_float(ceil(args[0].as.f));
  if (args[0].tag == T_RATIONAL) {
    mpz_t z;
    mpz_init(z);
    mpz_cdiv_q(z, mpq_numref(args[0].as.rational->q), mpq_denref(args[0].as.rational->q));
    Value result = mpz_to_int_value(z, "ceiling");
    mpz_clear(z);
    return result;
  }
  creme_abort("ceiling: not a number");
}
static Value bi_truncate(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "truncate");
  if (args[0].tag == T_INT || args[0].tag == T_BIGINT) return args[0];
  if (args[0].tag == T_FLOAT) return v_float(trunc(args[0].as.f));
  if (args[0].tag == T_RATIONAL) {
    mpz_t z;
    mpz_init(z);
    mpz_tdiv_q(z, mpq_numref(args[0].as.rational->q), mpq_denref(args[0].as.rational->q));
    Value result = mpz_to_int_value(z, "truncate");
    mpz_clear(z);
    return result;
  }
  creme_abort("truncate: not a number");
}
static Value bi_exact(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "exact");
  if (args[0].tag == T_INT || args[0].tag == T_BIGINT || args[0].tag == T_RATIONAL) return args[0];
  /* Truncates rather than finding the float's own exact rational value
   * (native's to_exact does the latter via BigRational -- see
   * builtin_helpers.cr) -- a pre-existing simplification of this
   * prototype's inexact->exact, unchanged/not in scope here. */
  if (args[0].tag == T_FLOAT) return v_int((int64_t)args[0].as.f);
  creme_abort("exact: not a number");
}
static Value bi_inexact(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "inexact");
  if (args[0].tag == T_FLOAT) return args[0];
  if (args[0].tag == T_INT) return v_float((double)args[0].as.i);
  if (args[0].tag == T_BIGINT) return v_float(mpz_get_d(args[0].as.bigint->z));
  if (args[0].tag == T_RATIONAL) return v_float(mpq_get_d(args[0].as.rational->q));
  creme_abort("inexact: not a number");
}

/* ---- (scheme complex) -- mirrors src/creme/modules/scheme/complex.cr's
 * own small surface exactly (make-rectangular/make-polar/real-part/
 * imag-part/magnitude/angle); complex?/number? are above, alongside the
 * other predicates. This IS the complete native surface, not a subset --
 * nothing was left out here. ---- */
static int is_real_component(Value v) { return v.tag == T_INT || v.tag == T_BIGINT || v.tag == T_FLOAT || v.tag == T_RATIONAL; }

static Value bi_make_rectangular(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 2 || !is_real_component(args[0]) || !is_real_component(args[1])) {
    creme_abort("make-rectangular: expected two real numbers");
  }
  return make_complex(args[0], args[1]);
}

static Value bi_make_polar(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_exact_args(nargs, 2, "make-polar");
  double mag = as_double(args[0], "make-polar"), ang = as_double(args[1], "make-polar");
  return make_complex(v_float(mag * cos(ang)), v_float(mag * sin(ang)));
}

static Value bi_real_part(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_exact_args(nargs, 1, "real-part");
  if (args[0].tag == T_COMPLEX) return args[0].as.cplx->real;
  if (!is_real_component(args[0])) creme_abort("real-part: not a number");
  return args[0];
}

static Value bi_imag_part(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_exact_args(nargs, 1, "imag-part");
  if (args[0].tag == T_COMPLEX) return args[0].as.cplx->imag;
  if (!is_real_component(args[0])) creme_abort("imag-part: not a number");
  return v_int(0);
}

static Value bi_magnitude(VM *vm, Value *args, int nargs) {
  creme_check_exact_args(nargs, 1, "magnitude");
  if (args[0].tag == T_COMPLEX) {
    double re = as_double(args[0].as.cplx->real, "magnitude"), im = as_double(args[0].as.cplx->imag, "magnitude");
    return v_float(sqrt(re * re + im * im));
  }
  return bi_abs(vm, args, nargs);
}

static Value bi_angle(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_exact_args(nargs, 1, "angle");
  if (args[0].tag == T_COMPLEX) {
    return v_float(atan2(as_double(args[0].as.cplx->imag, "angle"), as_double(args[0].as.cplx->real, "angle")));
  }
  if (!is_real_component(args[0])) creme_abort("angle: not a number");
  return v_float(as_double(args[0], "angle") < 0 ? M_PI : 0.0);
}

/* ---- pairs / lists ---- */
Value bi_car(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1 || args[0].tag != T_PAIR) creme_abort("car: expected a pair"); return args[0].as.pair->car; }
Value bi_cdr(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1 || args[0].tag != T_PAIR) creme_abort("cdr: expected a pair"); return args[0].as.pair->cdr; }

/* set-car!/set-cdr! -- mutate a Pair's own field in place (Pair is a
 * real, individually GC_MALLOC'd struct -- see value.h -- so this is
 * just a direct field write, no copy-on-write or interning to worry
 * about); return unspecified (v_nil()), matching native's own contract
 * exactly. Like native, this does NOT detect/reject mutating a literal
 * constant (R7RS documents that as an error, but neither implementation
 * enforces it -- see icecreme/README.md's own note on this, mirroring the
 * Crystal-side spec suite's identical pending case). */
static Value bi_set_car_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2 || args[0].tag != T_PAIR) creme_abort("set-car!: expected a pair");
  args[0].as.pair->car = args[1];
  return v_nil();
}
static Value bi_set_cdr_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2 || args[0].tag != T_PAIR) creme_abort("set-cdr!: expected a pair");
  args[0].as.pair->cdr = args[1];
  return v_nil();
}

/* (scheme cxr)'s full caar..cddddr family, as REAL global procedures --
 * icecreme already handles a car/cdr/cadr/etc. CALL SITE via the fused Cxr op
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
    if (v.tag != T_PAIR) creme_abort("c%.*sr: expected a pair", n, ops);
    v = (ops[i] == 'a') ? v.as.pair->car : v.as.pair->cdr;
  }
  return v;
}

#define DEFINE_CXR(name, opstr)                                                     \
  static Value bi_##name(VM *vm, Value *args, int nargs) {                          \
    (void)vm;                                                                       \
    creme_check_exact_args(nargs, 1, #name);                                         \
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
Value bi_cons(VM *vm, Value *args, int nargs) { creme_check_min_args(nargs, 2, "cons"); return creme_cons(vm, args[0], args[1]); }
static Value bi_list(VM *vm, Value *args, int nargs) {
  Value r = v_nil();
  for (int i = nargs - 1; i >= 0; i--) r = creme_cons(vm, args[i], r);
  return r;
}
static Value bi_cons_star(VM *vm, Value *args, int nargs) {
  if (nargs == 0) return v_nil();
  Value r = args[nargs - 1];
  for (int i = nargs - 2; i >= 0; i--) r = creme_cons(vm, args[i], r);
  return r;
}
static Value bi_append(VM *vm, Value *args, int nargs) {
  if (nargs == 0) return v_nil();
  Value result = args[nargs - 1];
  for (int i = nargs - 2; i >= 0; i--) {
    int n = creme_list_length(args[i]);
    /* GC_MALLOC, not xmalloc/free: creme_list_to_values aborts (longjmp) on an
     * improper list, which would skip a trailing free(). The staged Values are
     * already reachable via args[i], so GC visibility is fine. */
    Value *tmp = GC_MALLOC(sizeof(Value) * (size_t)(n ? n : 1));
    creme_list_to_values(args[i], tmp, n, "append");
    for (int j = n - 1; j >= 0; j--) result = creme_cons(vm, tmp[j], result);
  }
  return result;
}
static Value bi_list_tail(VM *vm, Value *args, int nargs) {
  (void)vm;
  int64_t k0 = creme_arg_int(args, nargs, 1, "list-tail");
  Value cur = args[0];
  for (int64_t k = k0; k > 0; k--) {
    if (cur.tag != T_PAIR) creme_abort("list-tail: index out of range");
    cur = cur.as.pair->cdr;
  }
  return cur;
}
static Value bi_list_ref(VM *vm, Value *args, int nargs) {
  (void)vm;
  int64_t k0 = creme_arg_int(args, nargs, 1, "list-ref");
  Value cur = args[0];
  for (int64_t k = k0; k > 0; k--) {
    if (cur.tag != T_PAIR) creme_abort("list-ref: index out of range");
    cur = cur.as.pair->cdr;
  }
  if (cur.tag != T_PAIR) creme_abort("list-ref: index out of range");
  return cur.as.pair->car;
}
static Value bi_list_set(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 3, "list-set!");
  int64_t k0 = creme_arg_int(args, nargs, 1, "list-set!");
  Value cur = args[0];
  for (int64_t k = k0; k > 0; k--) {
    if (cur.tag != T_PAIR) creme_abort("list-set!: index out of range");
    cur = cur.as.pair->cdr;
  }
  if (cur.tag != T_PAIR) creme_abort("list-set!: index out of range");
  cur.as.pair->car = args[2];
  return v_nil();
}
static Value bi_make_list(VM *vm, Value *args, int nargs) {
  int64_t k = creme_arg_int(args, nargs, 0, "make-list");
  if (k < 0) creme_abort("make-list: invalid length %lld", (long long)k);
  Value fill = nargs >= 2 ? args[1] : v_bool(0);
  Value result = v_nil();
  for (int64_t i = 0; i < k; i++) result = creme_cons(vm, fill, result);
  return result;
}
static Value bi_list_copy(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 1, "list-copy");
  /* Shallow copy, preserving an improper tail as-is (R7RS: "if obj is
   * improper, the result is also improper, and the final cdr of obj is
   * the final cdr of the result"). */
  Value *items = NULL;
  int n = 0, cap = 0;
  Value cur = args[0];
  while (cur.tag == T_PAIR) {
    if (n >= cap) { cap = cap ? cap * 2 : 8; items = GC_REALLOC(items, sizeof(Value) * (size_t)cap); }
    items[n++] = cur.as.pair->car;
    cur = cur.as.pair->cdr;
  }
  Value result = cur; /* final (possibly non-nil) tail */
  for (int i = n - 1; i >= 0; i--) result = creme_cons(vm, items[i], result);
  return result;
}
static Value bi_last_pair(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_PAIR) creme_abort("last-pair: expected a non-empty list");
  Value cur = args[0];
  while (cur.as.pair->cdr.tag == T_PAIR) cur = cur.as.pair->cdr;
  return cur;
}
static Value bi_assoc(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "assoc");
  int has_pred = nargs >= 3;
  Value cur = args[1];
  while (cur.tag == T_PAIR) {
    Value entry = cur.as.pair->car;
    if (entry.tag == T_PAIR) {
      int match = has_pred ? !v_falsy(creme_apply(vm, args[2], (Value[]){args[0], entry.as.pair->car}, 2))
                            : creme_equal(entry.as.pair->car, args[0]);
      if (match) return entry;
    }
    cur = cur.as.pair->cdr;
  }
  return v_bool(0);
}
static Value bi_assq(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "assq");
  Value cur = args[1];
  while (cur.tag == T_PAIR) {
    Value entry = cur.as.pair->car;
    if (entry.tag == T_PAIR && creme_eqv(entry.as.pair->car, args[0])) return entry;
    cur = cur.as.pair->cdr;
  }
  return v_bool(0);
}
static Value bi_member(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "member");
  int has_pred = nargs >= 3;
  Value cur = args[1];
  while (cur.tag == T_PAIR) {
    int match = has_pred ? !v_falsy(creme_apply(vm, args[2], (Value[]){args[0], cur.as.pair->car}, 2))
                          : creme_equal(cur.as.pair->car, args[0]);
    if (match) return cur;
    cur = cur.as.pair->cdr;
  }
  return v_bool(0);
}
static Value bi_memq(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "memq");
  Value cur = args[1];
  while (cur.tag == T_PAIR) {
    if (creme_eqv(cur.as.pair->car, args[0])) return cur;
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
 * creme_apply calls) that unwinds past this dynamic-wind via an outer
 * guard handler will run `after` during that handler's own unwind-stack
 * drain (OP_PUSHHANDLER's resume branch) -- exactly like a pending
 * parameterize restoration -- even though this C function's own call
 * frame never returns normally in that case (longjmp bypasses it
 * entirely). On the ordinary, no-exception path, thunk returns normally
 * here and we pop + run our own action directly. */
static Value bi_dynamic_wind(VM *vm, Value *args, int nargs) {
  creme_check_exact_args(nargs, 3, "dynamic-wind");
  Value before = args[0], thunk = args[1], after = args[2];
  creme_apply(vm, before, NULL, 0);
  if (vm->n_unwind >= CREME_UNWIND_CAP) creme_abort("icecreme: parameterize/dynamic-wind unwind stack full (CREME_UNWIND_CAP=%d)", CREME_UNWIND_CAP);
  UnwindAction *ua = &vm->unwind_stack[vm->n_unwind++];
  ua->kind = UNWIND_DYNAMIC_WIND;
  ua->after = after;
  Value result = creme_apply(vm, thunk, NULL, 0);
  /* Ordinary, no-exception return: pop our own action and run `after`
   * directly here (NOT via vm.c's own run_unwind_action, static/private
   * to that file -- this is the exact same one-line effect for the
   * DYNAMIC_WIND case). The guard-unwind path (vm.c) still handles the
   * exceptional case via that same UnwindAction, unaffected by this. */
  vm->n_unwind--;
  creme_apply(vm, after, NULL, 0);
  return result;
}

/* (call/cc proc) / (call-with-current-continuation proc) -- an ESCAPE-
 * ONLY (one-shot, upward) continuation: captures the current point via
 * setjmp, wraps it in a T_CONTINUATION Value, and calls `proc` with it
 * as the sole argument. If `proc` returns normally (never invokes the
 * continuation), call/cc itself returns that value, same as an ordinary
 * call. If the continuation IS invoked (immediately, or arbitrarily
 * deep -- through further nested creme_apply calls, e.g. a for-each
 * callback), dispatch_call/creme_apply's own T_CONTINUATION case (vm.c)
 * unwinds pending dynamic-wind/parameterize actions and longjmps
 * straight back to the setjmp call site below, which returns k->result
 * instead. See value.h's own Continuation doc comment for why this is
 * NOT a general re-enterable continuation. */
static Value bi_call_cc(VM *vm, Value *args, int nargs) {
  creme_check_exact_args(nargs, 1, "call/cc");
  Continuation *k = GC_MALLOC(sizeof(Continuation));
  k->depth = vm->depth;
  k->unwind_mark = vm->n_unwind;
  if (setjmp(k->buf) != 0) return k->result;
  Value kval = v_continuation(k);
  return creme_apply(vm, args[0], &kval, 1);
}

/* ---- higher-order procedures (creme_apply, vm.c, is the reentrant "call a
 * Scheme value from C" helper these all need). ---- */
static Value bi_apply(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "apply");
  int n_extra = nargs - 2;
  Value list_arg = args[nargs - 1];
  int n_list = 0;
  Value c = list_arg;
  while (c.tag == T_PAIR) { n_list++; c = c.as.pair->cdr; }
  int total = n_extra + n_list;
  /* GC_MALLOC (not xmalloc/free): creme_apply can escape via call/cc or raise
   * (a longjmp), which would skip a trailing free() and leak. */
  Value *call_args = GC_MALLOC(sizeof(Value) * (size_t)(total ? total : 1));
  for (int i = 0; i < n_extra; i++) call_args[i] = args[1 + i];
  c = list_arg;
  int idx = n_extra;
  while (c.tag == T_PAIR) { call_args[idx++] = c.as.pair->car; c = c.as.pair->cdr; }
  return creme_apply(vm, args[0], call_args, total);
}
static Value bi_map(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "map");
  int n_lists = nargs - 1;
  Value *cursors = GC_MALLOC(sizeof(Value) * (size_t)n_lists);
  Value *items = GC_MALLOC(sizeof(Value) * (size_t)n_lists);
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
     * GC-visible so a later creme_apply's own allocations can't collect an
     * earlier iteration's result out from under this loop. */
    Value r = creme_apply(vm, args[0], items, n_lists);
    if (acc_len >= acc_cap) { acc_cap = acc_cap ? acc_cap * 2 : 8; acc = GC_REALLOC(acc, sizeof(Value) * (size_t)acc_cap); }
    acc[acc_len++] = r;
  }
  Value result = v_nil();
  for (int i = acc_len - 1; i >= 0; i--) result = creme_cons(vm, acc[i], result);
  return result;
}
static Value bi_for_each(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "for-each");
  int n_lists = nargs - 1;
  Value *cursors = GC_MALLOC(sizeof(Value) * (size_t)n_lists);
  Value *items = GC_MALLOC(sizeof(Value) * (size_t)n_lists);
  for (int i = 0; i < n_lists; i++) cursors[i] = args[1 + i];
  for (;;) {
    int done = 0;
    for (int i = 0; i < n_lists; i++) if (cursors[i].tag != T_PAIR) { done = 1; break; }
    if (done) break;
    for (int i = 0; i < n_lists; i++) { items[i] = cursors[i].as.pair->car; cursors[i] = cursors[i].as.pair->cdr; }
    creme_apply(vm, args[0], items, n_lists);
  }
  return v_nil();
}
static Value bi_vector_map(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "vector-map");
  int n_vecs = nargs - 1;
  int minlen = -1;
  for (int i = 0; i < n_vecs; i++) {
    if (args[1 + i].tag != T_VECTOR) creme_abort("vector-map: expected a vector");
    int len = args[1 + i].as.vec->len;
    if (minlen < 0 || len < minlen) minlen = len;
  }
  Vector *result = GC_MALLOC(sizeof(Vector));
  result->len = minlen;
  result->items = GC_MALLOC(sizeof(Value) * (size_t)(minlen ? minlen : 1));
  Value *items = GC_MALLOC(sizeof(Value) * (size_t)n_vecs);
  for (int i = 0; i < minlen; i++) {
    for (int j = 0; j < n_vecs; j++) items[j] = args[1 + j].as.vec->items[i];
    result->items[i] = creme_apply(vm, args[0], items, n_vecs);
  }
  return v_vector(result);
}
static Value bi_vector_for_each(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "vector-for-each");
  int n_vecs = nargs - 1;
  int minlen = -1;
  for (int i = 0; i < n_vecs; i++) {
    if (args[1 + i].tag != T_VECTOR) creme_abort("vector-for-each: expected a vector");
    int len = args[1 + i].as.vec->len;
    if (minlen < 0 || len < minlen) minlen = len;
  }
  Value *items = GC_MALLOC(sizeof(Value) * (size_t)n_vecs);
  for (int i = 0; i < minlen; i++) {
    for (int j = 0; j < n_vecs; j++) items[j] = args[1 + j].as.vec->items[i];
    creme_apply(vm, args[0], items, n_vecs);
  }
  return v_nil();
}
static Value bi_string_for_each(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "string-for-each");
  int n_strs = nargs - 1;
  int minlen = -1;
  for (int i = 0; i < n_strs; i++) {
    if (args[1 + i].tag != T_STR) creme_abort("string-for-each: expected a string");
    int len = args[1 + i].aux;
    if (minlen < 0 || len < minlen) minlen = len;
  }
  Value *chars = GC_MALLOC(sizeof(Value) * (size_t)n_strs);
  for (int idx = 0; idx < minlen; idx++) {
    for (int i = 0; i < n_strs; i++) chars[i] = v_char((unsigned char)args[1 + i].as.chars[idx]);
    creme_apply(vm, args[0], chars, n_strs);
  }
  return v_nil();
}
static Value bi_filter(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "filter");
  Value *acc = NULL;
  int len = 0, cap = 0;
  Value cur = args[1];
  while (cur.tag == T_PAIR) {
    Value item = cur.as.pair->car;
    Value keep = creme_apply(vm, args[0], &item, 1);
    if (!v_falsy(keep)) {
      if (len >= cap) { cap = cap ? cap * 2 : 8; acc = GC_REALLOC(acc, sizeof(Value) * (size_t)cap); }
      acc[len++] = item;
    }
    cur = cur.as.pair->cdr;
  }
  Value result = v_nil();
  for (int i = len - 1; i >= 0; i--) result = creme_cons(vm, acc[i], result);
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
  creme_check_min_args(nargs, 2, "call-with-values");
  Value produced = creme_apply(vm, args[0], NULL, 0);
  if (produced.tag == T_VALUES) {
    return creme_apply(vm, args[1], produced.as.values->items, produced.as.values->len);
  }
  return creme_apply(vm, args[1], &produced, 1);
}

/* ---- strings ---- */
Value bi_string_append(VM *vm, Value *args, int nargs) {
  (void)vm;
  size_t total = 0;
  for (int i = 0; i < nargs; i++) {
    if (args[i].tag != T_STR) creme_abort("string-append: expected a string");
    total += (size_t)args[i].aux;
  }
  char *buf = GC_MALLOC(total ? total : 1);
  size_t off = 0;
  for (int i = 0; i < nargs; i++) {
    memcpy(buf + off, args[i].as.chars, (size_t)args[i].aux);
    off += (size_t)args[i].aux;
  }
  return v_str(buf, (int)total);
}
/* Copies `len` bytes starting at `chars` into a fresh, independently owned
 * buffer — used everywhere a "new string" is conceptually supposed to be
 * independent of whatever it was derived from (substring, symbol<->string
 * conversion), now that T_STR is mutable via string-set!: aliasing the
 * source's buffer directly (as this prototype used to do) would let a
 * later mutation of one silently corrupt the other. */
static Value bi_substring(VM *vm, Value *args, int nargs) {
  (void)vm;
  int slen;
  const char *s = creme_arg_bytes(args, nargs, 0, "substring", &slen);
  int start = (int)creme_arg_int(args, nargs, 1, "substring");
  int end = (nargs >= 3 && args[2].tag == T_INT) ? (int)args[2].as.i : slen;
  if (start < 0 || end > slen || start > end) creme_abort("substring: index out of range");
  return creme_bytes_value(s + start, end - start);
}

static Value bi_string_copy(VM *vm, Value *args, int nargs) {
  (void)vm;
  int slen;
  const char *s = creme_arg_bytes(args, nargs, 0, "string-copy", &slen);
  int start = (nargs >= 2 && args[1].tag == T_INT) ? (int)args[1].as.i : 0;
  int end = (nargs >= 3 && args[2].tag == T_INT) ? (int)args[2].as.i : slen;
  if (start < 0 || end > slen || start > end) creme_abort("string-copy: index out of range");
  return creme_bytes_value(s + start, end - start);
}
static Value bi_string_to_list(VM *vm, Value *args, int nargs) {
  int len;
  const char *s = creme_arg_bytes(args, nargs, 0, "string->list", &len);
  Value r = v_nil();
  for (int i = len - 1; i >= 0; i--) r = creme_cons(vm, v_char((unsigned char)s[i]), r);
  return r;
}
static Value bi_list_to_string(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "list->string");
  int n = 0;
  Value c = args[0];
  while (c.tag == T_PAIR) { n++; c = c.as.pair->cdr; }
  char *buf = GC_MALLOC((size_t)(n ? n : 1));
  c = args[0];
  int i = 0;
  while (c.tag == T_PAIR) {
    if (c.as.pair->car.tag != T_CHAR) creme_abort("list->string: expected a list of chars");
    buf[i++] = (char)c.as.pair->car.as.i;
    c = c.as.pair->cdr;
  }
  return v_str(buf, n);
}
static Value bi_make_string(VM *vm, Value *args, int nargs) {
  (void)vm;
  int64_t n = creme_arg_int(args, nargs, 0, "make-string");
  if (n < 0 || n > INT_MAX) creme_abort("make-string: invalid length %lld", (long long)n);
  char fill = (nargs >= 2 && args[1].tag == T_CHAR) ? (char)args[1].as.i : ' ';
  char *buf = creme_alloc_array((size_t)n, 1, "make-string");
  memset(buf, fill, (size_t)n);
  return v_str(buf, (int)n);
}
static Value bi_string_ctor(VM *vm, Value *args, int nargs) {
  (void)vm;
  char *buf = GC_MALLOC((size_t)(nargs ? nargs : 1));
  for (int i = 0; i < nargs; i++) {
    if (args[i].tag != T_CHAR) creme_abort("string: expected chars");
    buf[i] = (char)args[i].as.i;
  }
  return v_str(buf, nargs);
}
static Value bi_string_eq(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "string=?");
  for (int i = 1; i < nargs; i++) {
    if (args[i - 1].tag != T_STR || args[i].tag != T_STR) creme_abort("string=?: expected strings");
    if (args[i - 1].aux != args[i].aux ||
        memcmp(args[i - 1].as.chars, args[i].as.chars, (size_t)args[i].aux) != 0) {
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
  int alen = a.aux, blen = b.aux;
  int n = alen < blen ? alen : blen;
  int c = n ? memcmp(a.as.chars, b.as.chars, (size_t)n) : 0;
  if (c != 0) return c;
  return alen == blen ? 0 : (alen < blen ? -1 : 1);
}
static Value string_chain(Value *args, int nargs, const char *who, int (*ok)(int)) {
  if (nargs < 2) creme_abort("%s: expected at least two strings", who);
  for (int i = 1; i < nargs; i++) {
    if (args[i - 1].tag != T_STR || args[i].tag != T_STR) creme_abort("%s: expected strings", who);
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
  creme_check_min_args(nargs, 2, "symbol=?");
  for (int i = 1; i < nargs; i++) {
    if (args[i - 1].tag != T_SYM || args[i].tag != T_SYM) creme_abort("symbol=?: expected symbols");
    if (args[i - 1].aux != args[i].aux ||
        memcmp(args[i - 1].as.chars, args[i].as.chars, (size_t)args[i].aux) != 0) {
      return v_bool(0);
    }
  }
  return v_bool(1);
}

static Value bi_boolean_eq(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "boolean=?");
  for (int i = 1; i < nargs; i++) {
    if (args[i - 1].tag != T_BOOL || args[i].tag != T_BOOL) creme_abort("boolean=?: expected booleans");
    if (args[i - 1].as.b != args[i].as.b) return v_bool(0);
  }
  return v_bool(1);
}

/* (string-map proc str1 str2 ...): applies proc across the Nth char of
 * every string argument (stopping at the shortest one), building a new
 * string from proc's own char results -- mirrors native's own
 * string_map exactly (min length, one call per index). */
static Value bi_string_map(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "string-map");
  int nstrs = nargs - 1;
  int minlen = -1;
  for (int i = 1; i < nargs; i++) {
    if (args[i].tag != T_STR) creme_abort("string-map: expected a string");
    if (minlen < 0 || args[i].aux < minlen) minlen = args[i].aux;
  }
  char *buf = GC_MALLOC((size_t)(minlen ? minlen : 1));
  Value *call_args = GC_MALLOC(sizeof(Value) * (size_t)nstrs);
  for (int i = 0; i < minlen; i++) {
    for (int s = 0; s < nstrs; s++) call_args[s] = v_char((unsigned char)args[1 + s].as.chars[i]);
    Value result = creme_apply(vm, args[0], call_args, nstrs);
    if (result.tag != T_CHAR) creme_abort("string-map: expected the function to return a char");
    buf[i] = (char)result.as.i;
  }
  return v_str(buf, minlen);
}

/* (string-copy! to at from [start [end]]): icecreme strings are mutable byte
 * buffers (see string-set!'s own in-place write) -- memmove (not
 * memcpy) since `to` and `from` may be the SAME string with an
 * overlapping range. */
static Value bi_string_copy_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  int tolen, fromlen;
  const char *to = creme_arg_bytes(args, nargs, 0, "string-copy!", &tolen);
  int64_t at = creme_arg_int(args, nargs, 1, "string-copy!"); /* int64: (int)at + count overflows */
  const char *from = creme_arg_bytes(args, nargs, 2, "string-copy!", &fromlen);
  int first, last;
  byte_range_args(args, nargs, 3, fromlen, &first, &last);
  int count = last - first;
  if (at < 0 || at + count > tolen) creme_abort("string-copy!: destination range out of bounds");
  memmove((char *)to + (int)at, from + first, (size_t)count);
  return v_nil();
}

static Value bi_string_fill_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  int slen;
  const char *s = creme_arg_bytes(args, nargs, 0, "string-fill!", &slen);
  int64_t c = creme_arg_char(args, nargs, 1, "string-fill!");
  int first, last;
  byte_range_args(args, nargs, 2, slen, &first, &last);
  memset((char *)s + first, (int)(unsigned char)c, (size_t)(last - first));
  return v_nil();
}

static Value bi_string_to_vector(VM *vm, Value *args, int nargs) {
  (void)vm;
  int slen;
  const char *s = creme_arg_bytes(args, nargs, 0, "string->vector", &slen);
  int first, last;
  byte_range_args(args, nargs, 1, slen, &first, &last);
  int len = last - first;
  Vector *vec = GC_MALLOC(sizeof(Vector));
  vec->len = len;
  vec->items = GC_MALLOC(sizeof(Value) * (size_t)(len ? len : 1));
  for (int i = 0; i < len; i++) vec->items[i] = v_char((unsigned char)s[first + i]);
  return v_vector(vec);
}

static Value bi_vector_to_string(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_VECTOR) creme_abort("vector->string: expected a vector");
  Vector *vec = args[0].as.vec;
  int first, last;
  byte_range_args(args, nargs, 1, vec->len, &first, &last);
  int len = last - first;
  char *buf = GC_MALLOC((size_t)(len ? len : 1));
  for (int i = 0; i < len; i++) {
    if (vec->items[first + i].tag != T_CHAR) creme_abort("vector->string: expected a vector of chars");
    buf[i] = (char)vec->items[first + i].as.i;
  }
  return v_str(buf, len);
}
/* Optional 2nd arg: an explicit radix (2/8/10/16), needed by (creme
 * compiler reader)'s own #b/#o/#x-prefixed literal parsing -- previously
 * silently ignored here (always base 10), so a hex/octal/binary literal
 * whose digits aren't ALSO valid decimal digits (e.g. "1A" for #x1A)
 * failed to parse under icecreme specifically (reader.sld delegates the
 * actual digit-parsing to this builtin). Floats only ever make sense in
 * base 10 (R7RS has no hex/octal/binary float syntax), so strtod is only
 * tried there. */
static Value bi_string_to_number(VM *vm, Value *args, int nargs) {
  (void)vm;
  int len;
  const char *s = creme_arg_bytes(args, nargs, 0, "string->number", &len);
  int radix = 10;
  if (nargs >= 2) radix = (int)creme_arg_int(args, nargs, 1, "string->number");
  /* strtoll's behavior is undefined for any base other than 0 or 2..36. */
  if (radix < 2 || radix > 36) creme_abort("string->number: radix must be between 2 and 36, got %d", radix);
  char *buf = xmalloc((size_t)len + 1);
  memcpy(buf, s, (size_t)len);
  buf[len] = 0;
  char *endptr;
  errno = 0;
  long long iv = strtoll(buf, &endptr, radix);
  if (endptr != buf && *endptr == 0) {
    if (errno != ERANGE) {
      free(buf);
      return v_int(iv);
    }
    /* strtoll itself overflowed -- the text is still a syntactically
     * valid integer (endptr consumed it in full), just too large for
     * int64_t, so escalate to mpz_set_str instead of falling through to
     * the float/false paths below. */
    mpz_t z;
    mpz_init(z);
    int rc = mpz_set_str(z, buf, radix);
    free(buf);
    if (rc != 0) {
      mpz_clear(z);
      return v_bool(0); /* unreachable in practice (strtoll already validated the digits) */
    }
    Value result = make_bigint_from_mpz(z);
    mpz_clear(z);
    return result;
  }
  if (radix == 10) {
    double dv = strtod(buf, &endptr);
    if (endptr != buf && *endptr == 0) { free(buf); return v_float(dv); }
  }
  free(buf);
  return v_bool(0);
}
/* number->string's optional radix arg -- mirrors native's own
 * number_to_string (strings.cr): radix other than 10 only applies to
 * exact integers (R7RS leaves a non-decimal radix on an inexact/
 * non-integer number unspecified), lowercase a-z for digits above 9,
 * same as Crystal's Int#to_s(radix). Used to be silently ignored here
 * (always base 10) -- e.g. `(number->string 12 2)` came out "12"
 * instead of "1100". */
Value bi_number_to_string(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "number->string");
  int radix = 10;
  if (nargs >= 2) {
    if (args[1].tag != T_INT) creme_abort("number->string: expected an integer radix");
    radix = (int)args[1].as.i;
  }
  /* Radix must be 2..36: radix 0 divides by zero and radix 1 never shrinks
   * `un`, spinning forever and overrunning the tmp[] stack buffer below. */
  if (radix < 2 || radix > 36) creme_abort("number->string: radix must be between 2 and 36, got %d", radix);
  char buf[128];
  int len;
  if (radix != 10) {
    if (args[0].tag != T_INT && args[0].tag != T_BIGINT) creme_abort("number->string: radix %d requires an exact integer", radix);
    /* GMP's mpz_get_str supports any base 2..62 natively (lowercase a-z
     * for 11..36, matching this function's own long-standing digit
     * convention) -- simpler than a hand-rolled digit loop, and handles
     * T_BIGINT for free. */
    mpz_t z;
    mpz_init(z);
    value_to_mpz(args[0], z, "number->string");
    char *s = mpz_get_str(NULL, radix, z);
    mpz_clear(z);
    return creme_bytes_value(s, (int)strlen(s));
  } else if (args[0].tag == T_INT) {
    len = snprintf(buf, sizeof(buf), "%lld", (long long)args[0].as.i);
  } else if (args[0].tag == T_BIGINT) {
    char *s = mpz_get_str(NULL, 10, args[0].as.bigint->z);
    return creme_bytes_value(s, (int)strlen(s));
  } else if (args[0].tag == T_FLOAT) {
    double f = args[0].as.f;
    if (fabs(f) < 1e15 && f == (double)(int64_t)f) {
      len = snprintf(buf, sizeof(buf), "%lld.0", (long long)f);
    } else {
      len = snprintf(buf, sizeof(buf), "%.17g", f);
    }
  } else {
    creme_abort("number->string: not a number");
  }
  return creme_bytes_value(buf, len);
}
static Value bi_string_to_symbol(VM *vm, Value *args, int nargs) {
  (void)vm;
  int len;
  const char *s = creme_arg_bytes(args, nargs, 0, "string->symbol", &len);
  return creme_sym_value(s, len);
}
static Value bi_symbol_to_string(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1 || args[0].tag != T_SYM) creme_abort("symbol->string: expected a symbol"); return creme_bytes_value(args[0].as.chars, args[0].aux); }

/* (creme introspection)'s gensym -- a distinct symbol each call
 * ("prefix__N", N a process-wide counter), needed by defmacro-based
 * capture-avoidance idioms (e.g. modules/creme/compiler/compiler.sld's
 * own swap!-with-gensym pattern, exercised directly by spec/creme/
 * macro_spec.scm). Mirrors src/creme/modules/scheme/base/misc.cr's own
 * gensym exactly (prefix defaults to "g" with no argument). */
static int64_t g_gensym_counter = 0;
static Value bi_gensym(VM *vm, Value *args, int nargs) {
  (void)vm;
  const char *prefix_chars = "g";
  int prefix_len = 1;
  if (nargs >= 1) {
    if (args[0].tag != T_STR && args[0].tag != T_SYM) creme_abort("gensym: expected a string or symbol prefix");
    prefix_chars = args[0].as.chars;
    prefix_len = args[0].aux;
  }
  g_gensym_counter++;
  int cap = prefix_len + 32;
  char *buf = GC_MALLOC((size_t)cap);
  int n = snprintf(buf, (size_t)cap, "%.*s__%lld", prefix_len, prefix_chars, (long long)g_gensym_counter);
  return v_sym(buf, n);
}
static Value bi_char_to_integer(VM *vm, Value *args, int nargs) { (void)vm; return v_int(creme_arg_char(args, nargs, 0, "char->integer")); }
static Value bi_integer_to_char(VM *vm, Value *args, int nargs) { (void)vm; return v_char(creme_arg_int(args, nargs, 0, "integer->char")); }
static Value bi_char_eq(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "char=?");
  for (int i = 1; i < nargs; i++) {
    if (args[i - 1].tag != T_CHAR || args[i].tag != T_CHAR) creme_abort("char=?: expected chars");
    if (args[i - 1].as.i != args[i].as.i) return v_bool(0);
  }
  return v_bool(1);
}

static Value bi_char_lt(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "char<?");
  for (int i = 1; i < nargs; i++) {
    if (args[i - 1].tag != T_CHAR || args[i].tag != T_CHAR) creme_abort("char<?: expected chars");
    if (!(args[i - 1].as.i < args[i].as.i)) return v_bool(0);
  }
  return v_bool(1);
}

static Value bi_char_gt(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "char>?");
  for (int i = 1; i < nargs; i++) {
    if (args[i - 1].tag != T_CHAR || args[i].tag != T_CHAR) creme_abort("char>?: expected chars");
    if (!(args[i - 1].as.i > args[i].as.i)) return v_bool(0);
  }
  return v_bool(1);
}

static Value bi_char_le(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "char<=?");
  for (int i = 1; i < nargs; i++) {
    if (args[i - 1].tag != T_CHAR || args[i].tag != T_CHAR) creme_abort("char<=?: expected chars");
    if (!(args[i - 1].as.i <= args[i].as.i)) return v_bool(0);
  }
  return v_bool(1);
}

static Value bi_char_ge(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "char>=?");
  for (int i = 1; i < nargs; i++) {
    if (args[i - 1].tag != T_CHAR || args[i].tag != T_CHAR) creme_abort("char>=?: expected chars");
    if (!(args[i - 1].as.i >= args[i].as.i)) return v_bool(0);
  }
  return v_bool(1);
}

/* ASCII-only (matches strings.c's own upcase/downcase scope, and icecreme's
 * bytes-not-Unicode string-ref elsewhere) -- the self-hosted reader only
 * ever calls this on single-byte ASCII characters (radix/exactness prefix
 * letters, hex digits), so full Unicode case-folding isn't needed here. */
static Value bi_char_downcase(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 1 || args[0].tag != T_CHAR) creme_abort("char-downcase: expected a char");
  int64_t c = args[0].as.i;
  if (c >= 'A' && c <= 'Z') c = c - 'A' + 'a';
  return v_char(c);
}

static Value bi_char_upcase(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 1 || args[0].tag != T_CHAR) creme_abort("char-upcase: expected a char");
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
  int64_t c = creme_arg_char(args, nargs, 0, "digit-value");
  return (c >= '0' && c <= '9') ? v_int(c - '0') : v_bool(0);
}

static Value bi_char_alphabetic_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  return v_bool(isalpha((int)creme_arg_char(args, nargs, 0, "char-alphabetic?")) != 0);
}

static Value bi_char_numeric_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  return v_bool(isdigit((int)creme_arg_char(args, nargs, 0, "char-numeric?")) != 0);
}

static Value bi_char_whitespace_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  return v_bool(isspace((int)creme_arg_char(args, nargs, 0, "char-whitespace?")) != 0);
}

static Value bi_char_upper_case_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  return v_bool(isupper((int)creme_arg_char(args, nargs, 0, "char-upper-case?")) != 0);
}

static Value bi_char_lower_case_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  return v_bool(islower((int)creme_arg_char(args, nargs, 0, "char-lower-case?")) != 0);
}

static char creme_ascii_lower(char c) { return (c >= 'A' && c <= 'Z') ? (char)(c - 'A' + 'a') : c; }

/* char-ci=?/</>/<=/>= chain comparisons -- lowers both sides of each
 * adjacent pair before comparing, mirroring native's char_chain(...,
 * case_insensitive: true). */
static Value char_ci_chain(Value *args, int nargs, const char *who, int (*cmp)(char, char)) {
  if (nargs < 2) creme_abort("%s: expected at least two chars", who);
  for (int i = 1; i < nargs; i++) {
    if (args[i - 1].tag != T_CHAR || args[i].tag != T_CHAR) creme_abort("%s: expected chars", who);
    char a = creme_ascii_lower((char)args[i - 1].as.i), b = creme_ascii_lower((char)args[i].as.i);
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
  int alen = a.aux, blen = b.aux;
  int n = alen < blen ? alen : blen;
  for (int i = 0; i < n; i++) {
    char ca = creme_ascii_lower(a.as.chars[i]), cb = creme_ascii_lower(b.as.chars[i]);
    if (ca != cb) return ca < cb ? -1 : 1;
  }
  return alen == blen ? 0 : (alen < blen ? -1 : 1);
}
static Value string_ci_chain(Value *args, int nargs, const char *who, int (*ok)(int)) {
  if (nargs < 2) creme_abort("%s: expected at least two strings", who);
  for (int i = 1; i < nargs; i++) {
    if (args[i - 1].tag != T_STR || args[i].tag != T_STR) creme_abort("%s: expected strings", who);
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
  return creme_vector_from_values(args, nargs);
}
static Value bi_vector_to_list(VM *vm, Value *args, int nargs) {
  if (nargs < 1 || args[0].tag != T_VECTOR) creme_abort("vector->list: expected a vector");
  Vector *vec = args[0].as.vec;
  /* Optional start/end -- R7RS's (vector->list vector [start [end]]),
   * defaulting to the whole vector. (list->vector has no such args in
   * R7RS -- only this direction does -- so that one is left as-is.) */
  if (nargs >= 2 && args[1].tag != T_INT) creme_abort("vector->list: start must be an integer");
  if (nargs >= 3 && args[2].tag != T_INT) creme_abort("vector->list: end must be an integer");
  int64_t start = nargs >= 2 ? args[1].as.i : 0;
  int64_t end = nargs >= 3 ? args[2].as.i : vec->len;
  if (start < 0 || end > vec->len || start > end) creme_abort("vector->list: start/end out of range");
  Value r = v_nil();
  for (int64_t i = end - 1; i >= start; i--) r = creme_cons(vm, vec->items[i], r);
  return r;
}
static Value bi_list_to_vector(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "list->vector");
  int n = creme_list_length(args[0]);
  Value *items = GC_MALLOC(sizeof(Value) * (size_t)(n ? n : 1));
  creme_list_to_values(args[0], items, n, "list->vector");
  return creme_vector_from_values(items, n);
}

/* ---- misc ---- */
/* Builds a real condition (message + irritants list, not just a printed
 * string) so guard's error-object-message/error-object-irritants work
 * correctly on it -- unlike the old always-exits version, this raises to
 * the nearest guard handler if one is installed (see creme_raise_condition/
 * Group G). */
static Value bi_error(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 1, "error");
  char *buf = NULL;
  size_t size = 0;
  FILE *ms = open_memstream(&buf, &size);
  /* Only the message (args[0]) goes into the condition's own message
   * field -- error-object-message must return the BARE message, not
   * message+irritants concatenated (this used to print every irritant
   * into the same buffer too, so error-object-message came back e.g.
   * "boom 1 2 3" instead of "boom"). Irritants are already carried
   * separately below (error-object-irritants), so nothing is lost. */
  print_value(ms, args[0]);
  fclose(ms);

  Value irritants = v_nil();
  for (int i = nargs - 1; i >= 1; i--) irritants = creme_cons(vm, args[i], irritants);
  Value cond = creme_make_condition(vm, buf, size, irritants);
  free(buf);

  if (vm->n_handlers > 0) creme_raise_condition(vm, cond);

  /* Uncaught (no guard installed): print message + irritants together
   * for a human to read, same shape the old always-concatenated buffer
   * had -- this is just diagnostic stderr text, not the stored
   * condition, so it's fine (and more useful) to include irritants here
   * even though the condition's own message field no longer does. */
  Value msg = cond.as.record->fields[0];
  fwrite(msg.as.chars, 1, (size_t)msg.aux, stderr);
  for (int i = 1; i < nargs; i++) {
    fputc(' ', stderr);
    print_value(stderr, args[i]);
  }
  fputc('\n', stderr);
  exit(1);
}

/* Shared fallback for raise/raise-continuable when nothing catches
 * `obj`: escalate to the nearest `guard` handler if one is installed
 * (creme_raise_condition longjmps, never returns), otherwise print and
 * exit -- same shape bi_raise's body always had, factored out so
 * raise-continuable's own no-handler-installed case (which needs the
 * identical fallback, see its own comment) doesn't duplicate it. */
static _Noreturn void raise_uncaught_or_to_guard(VM *vm, Value obj) {
  if (vm->n_handlers > 0) creme_raise_condition(vm, obj);
  char *buf = NULL;
  size_t size = 0;
  FILE *ms = open_memstream(&buf, &size);
  fputs("uncaught exception: ", ms);
  print_value(ms, obj);
  fclose(ms);
  fwrite(buf, 1, size, stderr);
  fputc('\n', stderr);
  free(buf);
  exit(1);
}

/* raise: signals `args[0]` AS-IS (no message/irritants wrapping -- unlike
 * `error`, the condition IS whatever value was passed, e.g. a bare
 * symbol), matching R7RS. Per R7RS (and native's own raise_,
 * exceptions.cr), a plain (non-continuable) raise must first try the
 * CURRENT with-exception-handler handler -- popped while it runs, so a
 * handler that itself raises sees the next-outer handler, never itself
 * -- and only fall through to the guard/top-level unwind below if that
 * handler returns normally instead of escaping (a returning handler has
 * nowhere for its value to go on a non-continuable raise). This used to
 * only drive the C-level guard/GuardHandler longjmp stack directly,
 * never consulting an installed with-exception-handler at all -- a
 * genuine R7RS-correctness gap now fixed alongside promoting with-
 * exception-handler/raise-continuable themselves to real C builtins
 * (see icecreme/vm.h's own UNWIND_EXC_HANDLER doc comment). */
static Value bi_raise(VM *vm, Value *args, int nargs) {
  creme_check_exact_args(nargs, 1, "raise");
  if (vm->n_exc_handlers > 0) {
    Value handler = vm->exc_handlers[--vm->n_exc_handlers];
    creme_apply(vm, handler, args, 1);
    vm->exc_handlers[vm->n_exc_handlers++] = handler;
    /* Handler returned normally -- falls through below. */
  }
  raise_uncaught_or_to_guard(vm, args[0]);
}

/* raise-continuable: same handler lookup/pop as raise, but returns the
 * handler's own value in-line on an ordinary, non-escaping return --
 * exactly what makes this usable for e.g. a "supply a substitute value
 * and keep going" handler, unlike raise. If no handler is installed,
 * falls back to the SAME guard/top-level path raise itself uses
 * (matches native's own raise_continuable exactly -- NOT a distinct
 * "no handler installed" error the way the old icecreme/icecreme.scm
 * Scheme-level shim used to raise instead). */
static Value bi_raise_continuable(VM *vm, Value *args, int nargs) {
  creme_check_exact_args(nargs, 1, "raise-continuable");
  if (vm->n_exc_handlers > 0) {
    Value handler = vm->exc_handlers[--vm->n_exc_handlers];
    Value result = creme_apply(vm, handler, args, 1);
    vm->exc_handlers[vm->n_exc_handlers++] = handler;
    return result;
  }
  raise_uncaught_or_to_guard(vm, args[0]);
}

/* with-exception-handler: installs `handler` as the current exception
 * handler for the dynamic extent of `thunk` -- backed by a genuine
 * VM-wide handler stack (vm->exc_handlers) now, not a Scheme-level
 * mutable list (icecreme/icecreme.scm used to be the ONLY place this
 * existed, so a precompiled --emit-icecreme program could never use it at
 * all -- see that file's own updated comment). Reuses the SAME
 * unwind_stack mechanism dynamic-wind/parameterize already use (vm.h's
 * UnwindAction) so an error/continuation unwinding past this still
 * restores the handler stack correctly -- via a dedicated
 * UNWIND_EXC_HANDLER action that resets vm->n_exc_handlers to an
 * absolute remembered mark (see that kind's own doc comment for why
 * "restore to mark" is needed here instead of dynamic-wind's own
 * "call an ordinary after-thunk" shape). */
static Value bi_with_exception_handler(VM *vm, Value *args, int nargs) {
  creme_check_exact_args(nargs, 2, "with-exception-handler");
  Value handler = args[0], thunk = args[1];
  if (vm->n_exc_handlers >= CREME_EXC_HANDLERS_CAP) {
    creme_abort("with-exception-handler: handler stack full (CREME_EXC_HANDLERS_CAP=%d)", CREME_EXC_HANDLERS_CAP);
  }
  int mark = vm->n_exc_handlers;
  vm->exc_handlers[vm->n_exc_handlers++] = handler;
  if (vm->n_unwind >= CREME_UNWIND_CAP) creme_abort("icecreme: parameterize/dynamic-wind unwind stack full (CREME_UNWIND_CAP=%d)", CREME_UNWIND_CAP);
  UnwindAction *ua = &vm->unwind_stack[vm->n_unwind++];
  ua->kind = UNWIND_EXC_HANDLER;
  ua->mark = mark;
  Value result = creme_apply(vm, thunk, NULL, 0);
  vm->n_unwind--;
  vm->n_exc_handlers = mark;
  return result;
}

static Value bi_error_object_p(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 1, "error-object?");
  return v_bool(creme_is_condition(vm, args[0]));
}

static Value bi_error_object_message(VM *vm, Value *args, int nargs) {
  if (nargs < 1 || !creme_is_condition(vm, args[0])) creme_abort("error-object-message: expected an error object");
  return args[0].as.record->fields[0];
}

static Value bi_error_object_irritants(VM *vm, Value *args, int nargs) {
  if (nargs < 1 || !creme_is_condition(vm, args[0])) creme_abort("error-object-irritants: expected an error object");
  return args[0].as.record->fields[1];
}

/* read-error?/file-error? -- native (exceptions.cr) only returns #t for
 * a condition of a DISTINCT read-error/file-error record type, which
 * this VM doesn't have (creme_is_condition/get_condition_type is one
 * unified condition shape for everything `error`/`raise` produce, see
 * this file's own creme_make_condition). Every condition icecreme can
 * currently construct is that one unified shape, so these are honest
 * always-#f stubs for now -- a fully faithful port needs dedicated
 * read-error/file-error condition kinds raised by `read`/the file-port
 * builtins specifically, which is out of scope here. */
static Value bi_read_error_p(VM *vm, Value *args, int nargs) {
  (void)vm; (void)args;
  creme_check_min_args(nargs, 1, "read-error?");
  return v_bool(0);
}

static Value bi_file_error_p(VM *vm, Value *args, int nargs) {
  (void)vm; (void)args;
  creme_check_min_args(nargs, 1, "file-error?");
  return v_bool(0);
}

static Value bi_make_parameter(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 1, "make-parameter");
  Parameter *p = GC_MALLOC(sizeof(Parameter));
  if (nargs >= 2) {
    p->has_converter = 1;
    p->converter = args[1];
    p->value = creme_apply(vm, args[1], &args[0], 1);
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
  creme_check_min_args(nargs, 2, "time-difference");
  double a = args[0].tag == T_FLOAT ? args[0].as.f : (double)args[0].as.i;
  double b = args[1].tag == T_FLOAT ? args[1].as.f : (double)args[1].as.i;
  return v_float(a - b);
}

/* (creme time)'s remaining surface -- time_from_epoch's own icecreme
 * counterpart (time.cr): every one of these takes a Unix-epoch-seconds
 * float/int and reads it as UTC via gmtime_r (Time.unix_ms(...).to_utc,
 * native's own equivalent). time->string/string->time's format strings
 * are plain strftime/strptime directives (%Y-%m-%d %H:%M:%S, ...) --
 * every format string this project's own spec suite (time_spec.cr) uses
 * is already strftime-compatible, so no separate directive-translation
 * layer is needed the way (creme format) has for its own %-directives. */
static double as_epoch_seconds(Value v, const char *who) {
  if (v.tag == T_FLOAT) return v.as.f;
  if (v.tag == T_INT) return (double)v.as.i;
  creme_abort("%s: expected a number (Unix epoch seconds)", who);
}

static void epoch_to_tm(double epoch, const char *who, struct tm *out) {
  time_t secs = (time_t)epoch;
  if (!gmtime_r(&secs, out)) creme_abort("%s: invalid time value", who);
}

static Value bi_time_year(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "time-year");
  struct tm tmv;
  epoch_to_tm(as_epoch_seconds(args[0], "time-year"), "time-year", &tmv);
  return v_int(tmv.tm_year + 1900);
}

static Value bi_time_month(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "time-month");
  struct tm tmv;
  epoch_to_tm(as_epoch_seconds(args[0], "time-month"), "time-month", &tmv);
  return v_int(tmv.tm_mon + 1);
}

static Value bi_time_day(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "time-day");
  struct tm tmv;
  epoch_to_tm(as_epoch_seconds(args[0], "time-day"), "time-day", &tmv);
  return v_int(tmv.tm_mday);
}

static Value bi_time_hour(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "time-hour");
  struct tm tmv;
  epoch_to_tm(as_epoch_seconds(args[0], "time-hour"), "time-hour", &tmv);
  return v_int(tmv.tm_hour);
}

static Value bi_time_minute(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "time-minute");
  struct tm tmv;
  epoch_to_tm(as_epoch_seconds(args[0], "time-minute"), "time-minute", &tmv);
  return v_int(tmv.tm_min);
}

static Value bi_time_second(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "time-second");
  struct tm tmv;
  epoch_to_tm(as_epoch_seconds(args[0], "time-second"), "time-second", &tmv);
  return v_int(tmv.tm_sec);
}

static Value bi_time_add(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "time-add");
  return v_float(as_epoch_seconds(args[0], "time-add") + as_epoch_seconds(args[1], "time-add"));
}

static Value bi_time_to_string(VM *vm, Value *args, int nargs) {
  (void)vm;
  int fmtarglen;
  const char *fmtarg = creme_arg_bytes(args, nargs, 1, "time->string", &fmtarglen);
  struct tm tmv;
  epoch_to_tm(as_epoch_seconds(args[0], "time->string"), "time->string", &tmv);
  char fmt[256];
  int fmt_len = fmtarglen < (int)sizeof(fmt) - 1 ? fmtarglen : (int)sizeof(fmt) - 1;
  memcpy(fmt, fmtarg, (size_t)fmt_len);
  fmt[fmt_len] = '\0';
  char buf[512];
  size_t n = strftime(buf, sizeof(buf), fmt, &tmv);
  return creme_bytes_value(buf, (int)n);
}

/* A portable timegm(3) replacement -- civil_from_days is Howard Hinnant's
 * well-known days-since-epoch formula (proleptic Gregorian, valid for any
 * year), used here instead of the real timegm(3) since ITS availability
 * without extra feature-test-macro juggling differs across libc's (glibc
 * gates it behind _DEFAULT_SOURCE/_BSD_SOURCE, FreeBSD's behind
 * __BSD_VISIBLE/__ISO_C_VISIBLE>=2023 -- no single #define satisfies
 * both alongside strptime's own _XOPEN_SOURCE requirement on glibc). */
static int64_t days_from_civil(int64_t y, int m, int d) {
  y -= m <= 2;
  int64_t era = (y >= 0 ? y : y - 399) / 400;
  int64_t yoe = y - era * 400;
  int64_t doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
  int64_t doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097 + doe - 719468;
}

static int64_t tm_to_epoch_utc(const struct tm *tmv) {
  int64_t days = days_from_civil(tmv->tm_year + 1900, tmv->tm_mon + 1, tmv->tm_mday);
  return days * 86400 + tmv->tm_hour * 3600 + tmv->tm_min * 60 + tmv->tm_sec;
}

static Value bi_string_to_time(VM *vm, Value *args, int nargs) {
  (void)vm;
  int strarglen, fmtarglen;
  const char *strarg = creme_arg_bytes(args, nargs, 0, "string->time", &strarglen);
  const char *fmtarg = creme_arg_bytes(args, nargs, 1, "string->time", &fmtarglen);
  char str[512];
  int str_len = strarglen < (int)sizeof(str) - 1 ? strarglen : (int)sizeof(str) - 1;
  memcpy(str, strarg, (size_t)str_len);
  str[str_len] = '\0';
  char fmt[256];
  int fmt_len = fmtarglen < (int)sizeof(fmt) - 1 ? fmtarglen : (int)sizeof(fmt) - 1;
  memcpy(fmt, fmtarg, (size_t)fmt_len);
  fmt[fmt_len] = '\0';
  struct tm tmv;
  memset(&tmv, 0, sizeof(tmv));
  if (!strptime(str, fmt, &tmv)) creme_abort("string->time: could not parse '%s' with format '%s'", str, fmt);
  return v_float((double)tm_to_epoch_utc(&tmv));
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
  int namelen;
  const char *namearg = creme_arg_bytes(args, nargs, 0, "get-environment-variable", &namelen);
  char *name = xmalloc((size_t)namelen + 1);
  memcpy(name, namearg, (size_t)namelen);
  name[namelen] = 0;
  const char *val = getenv(name);
  free(name);
  if (!val) return v_bool(0);
  int len = (int)strlen(val);
  return creme_bytes_value(val, len);
}

/* (scheme process-context)'s get-environment-variables -- the whole
 * process environment as a (name . value) alist (env.cr's own
 * ENV.each). `environ` (POSIX, declared in unistd.h) is the same
 * NULL-terminated "NAME=value" array getenv/setenv themselves read/
 * write -- no separate snapshot to keep in sync. */
extern char **environ;

static Value bi_get_environment_variables(VM *vm, Value *args, int nargs) {
  (void)args; (void)nargs;
  Value result = v_nil();
  int n = 0;
  while (environ[n]) n++;
  for (int i = n - 1; i >= 0; i--) {
    const char *entry = environ[i];
    const char *eq = strchr(entry, '=');
    if (!eq) continue;
    int name_len = (int)(eq - entry);
    int val_len = (int)strlen(eq + 1);
    Value name = creme_bytes_value(entry, name_len);
    Value val = creme_bytes_value(eq + 1, val_len);
    result = creme_cons(vm, creme_cons(vm, name, val), result);
  }
  return result;
}

/* (scheme process-context)'s command-line -- see process.cr's own
 * command_line: (program-name . trailing-args), where "trailing-args"
 * is whatever icecreme's own argv held after the target file path (icecreme has
 * no other CLI surface a script would ever need to observe). Set once
 * by main() via creme_set_command_line_args, before anything runs. */
static Value bi_litstr_runtime(const char *s); /* defined further below */
static const char *g_cmdline_program = NULL;
static char **g_cmdline_args = NULL;
static int g_cmdline_n_args = 0;

void creme_set_command_line_args(const char *program_name, int argc, char **argv) {
  g_cmdline_program = program_name;
  g_cmdline_n_args = argc;
  g_cmdline_args = argv;
}

static Value bi_command_line(VM *vm, Value *args, int nargs) {
  (void)args; (void)nargs;
  Value result = v_nil();
  for (int i = g_cmdline_n_args - 1; i >= 0; i--) {
    result = creme_cons(vm, bi_litstr_runtime(g_cmdline_args[i]), result);
  }
  const char *prog = g_cmdline_program ? g_cmdline_program : "icecreme";
  return creme_cons(vm, bi_litstr_runtime(prog), result);
}

/* (creme env)'s set-environment-variable! -- a subprocess spawned via
 * process-run (icecreme/process.c) inherits its parent's environ automatically
 * (execvp doesn't touch it), so this is the one piece needed for a
 * icecreme-run parent to pass a flag down to an icecreme-run child it spawns (e.g.
 * spec/creme/main_spec.scm setting CREME_SPEC_DATA_MODE before spawning
 * each spec file). */
static Value bi_set_environment_variable(VM *vm, Value *args, int nargs) {
  (void)vm;
  int namelen, vallen;
  const char *namearg = creme_arg_bytes(args, nargs, 0, "set-environment-variable!", &namelen);
  const char *valarg = creme_arg_bytes(args, nargs, 1, "set-environment-variable!", &vallen);
  char *name = xmalloc((size_t)namelen + 1);
  memcpy(name, namearg, (size_t)namelen);
  name[namelen] = 0;
  char *val = xmalloc((size_t)vallen + 1);
  memcpy(val, valarg, (size_t)vallen);
  val[vallen] = 0;
  setenv(name, val, 1);
  free(name);
  free(val);
  return v_nil();
}

/* (creme env)'s delete-environment-variable! -- unsetenv is a no-op for a
 * key that was never set (matching native Crystal's ENV.delete semantics,
 * src/creme/modules/creme/env.cr), so no existence check is needed here. */
static Value bi_delete_environment_variable(VM *vm, Value *args, int nargs) {
  (void)vm;
  int namelen;
  const char *namearg = creme_arg_bytes(args, nargs, 0, "delete-environment-variable!", &namelen);
  char *name = xmalloc((size_t)namelen + 1);
  memcpy(name, namearg, (size_t)namelen);
  name[namelen] = 0;
  unsetenv(name);
  free(name);
  return v_nil();
}

static Value bi_litstr_runtime(const char *s) { return creme_cstr_value(s); }

/* Same as bi_litstr_runtime, but tagged as a symbol -- used for this
 * alist's own keys (vm/compiler/version/os/arch) so `(assq 'vm (runtime))`
 * works, matching introspection.cr's SchemeSym.of keys on the Crystal
 * side; the VALUES stay plain strings on both sides. */
static Value bi_litsym_runtime(const char *s) {
  int len = (int)strlen(s);
  char *buf = GC_MALLOC((size_t)len);
  memcpy(buf, s, (size_t)len);
  return v_sym(buf, len);
}

/* (runtime) -- an alist ((vm . "icecreme") (compiler . "self-hosted")
 * (version . "0.1.0") (os . <uname sysname>) (arch . <uname machine>)).
 * icecreme always reports vm = "icecreme" and compiler = "self-hosted" -- it has no
 * other way to run code at all (there is no native/tree-walking pipeline
 * here). See src/creme/modules/creme/introspection.cr's own `runtime`
 * for the Crystal-side twin of this builtin (vm = "crystal", compiler
 * "native" or "self-hosted" depending on how that process was invoked).
 * `version` is a hardcoded literal -- this project has no other
 * canonical version yet; keep this in sync BY HAND with introspection.cr's
 * own copy of the same literal. os/arch come from the real uname(2)
 * syscall (sys/utsname.h), matching what running `uname -s`/`uname -m`
 * yourself would show on this same machine. */
static Value bi_runtime(VM *vm, Value *args, int nargs) {
  (void)args; (void)nargs;
  struct utsname u;
  if (uname(&u) != 0) creme_abort("runtime: uname(2) failed");
  Value vm_pair = creme_cons(vm, bi_litsym_runtime("vm"), bi_litstr_runtime("icecreme"));
  Value compiler_pair = creme_cons(vm, bi_litsym_runtime("compiler"), bi_litstr_runtime("self-hosted"));
  Value version_pair = creme_cons(vm, bi_litsym_runtime("version"), bi_litstr_runtime("0.1.0")); /* keep in sync with introspection.cr's runtime */
  Value os_pair = creme_cons(vm, bi_litsym_runtime("os"), bi_litstr_runtime(u.sysname));
  Value arch_pair = creme_cons(vm, bi_litsym_runtime("arch"), bi_litstr_runtime(u.machine));
  return creme_cons(vm, vm_pair,
           creme_cons(vm, compiler_pair,
             creme_cons(vm, version_pair,
               creme_cons(vm, os_pair,
                 creme_cons(vm, arch_pair, v_nil())))));
}

/* (bound-names) -- a flat list of strings, one per currently-bound global
 * name in icecreme's own flat global table (vm->globals[0 .. vm->n_globals)).
 * Order is whatever order globals happen to sit in the table (insertion
 * order in practice) -- nothing downstream depends on a specific order.
 * Entries with .bound == 0 (declared but not yet defined) are skipped.
 * Used by the shared REPL's tab-completion (modules/creme/repl.sld) to
 * offer global bindings as completion candidates. */
static Value bi_bound_names(VM *vm, Value *args, int nargs) {
  (void)args; (void)nargs;
  Value result = v_nil();
  for (int i = vm->n_globals - 1; i >= 0; i--) {
    if (!vm->globals[i].bound) continue;
    result = creme_cons(vm, bi_litstr_runtime(vm->globals[i].name), result);
  }
  return result;
}

/* (scheme base)'s (features) -- was entirely unbound under icecreme ("unbound
 * variable: features"), a genuine, previously-undocumented gap
 * (--self-hosted never showed it since it still runs inside the
 * ordinary Crystal process, so an ordinary procedure call like this one
 * still resolves to Crystal's own native builtin regardless of the
 * self-hosted compiler's OWN, separate cond-expand-time feature check).
 * Matches native's own feature list exactly (interpreter.cr's own
 * `features`, verified directly) -- also the same list compiler.sld's
 * own cond-expand-known-features already hardcodes for its compile-time
 * `cond-expand` check, so the two stay in sync by construction as long
 * as both are updated together (there is no single shared source of
 * truth for this list across native/self-hosted). */
static Value bi_features(VM *vm, Value *args, int nargs) {
  (void)args; (void)nargs;
  return creme_cons(vm, bi_litsym_runtime("r7rs"),
           creme_cons(vm, bi_litsym_runtime("creme"),
             creme_cons(vm, bi_litsym_runtime("creme.cr"), v_nil())));
}

/* (creme introspection)'s macro?/record-fields -- see introspection.cr's
 * own macro_p/record_fields. macro? recognizes icecreme's own T_MACRO tag
 * (bound by a top-level defmacro/define-syntax, see vm.c's HelperForm);
 * record-fields returns a record instance's positional fields array as
 * an ordinary list, generic over every define-record-type type (matches
 * native's SchemeRecord#fields dispatch -- no per-type-specific code). */
static Value bi_macro_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "macro?");
  return v_bool(args[0].tag == T_MACRO);
}

static Value bi_record_fields(VM *vm, Value *args, int nargs) {
  if (nargs < 1 || args[0].tag != T_RECORD) creme_abort("record-fields: expected a record instance");
  SchemeRecord *rec = args[0].as.record;
  Value result = v_nil();
  for (int i = rec->type->n_fields - 1; i >= 0; i--) result = creme_cons(vm, rec->fields[i], result);
  return result;
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
  int64_t code = 0;
  if (nargs >= 1) {
    if (args[0].tag != T_INT) creme_abort("exit: expected an integer");
    code = args[0].as.i;
  }
  if (code < 0) code = 0;
  if (code > 255) code = 255;
  /* A profiled run (--profile) that ends via (exit) rather than falling
   * off the end of the script (main.c's normal post-run path) would
   * otherwise silently lose its report -- e.g. any program that never
   * returns on its own (a blocking server) but calls (exit) itself once
   * some condition is met. Only meaningful on the SAME vm --profile
   * enabled it on (see vm->profiler's own per-VM-instance doc comment,
   * vm.h) -- a spawned actor or (creme mux) worker/inline VM calling
   * (exit) here has its own, never-enabled profiler struct; the process-
   * wide native sampler (profiler.c's g_profiled_vm) still captured
   * every thread's C frames regardless, since that part isn't tied to
   * any specific VM instance. */
  if (vm->profiler.enabled) {
    creme_profiler_stop_native(vm);
    creme_profiler_report(vm);
  }
  exit((int)code);
}

/* Deeper car/cdr compositions -- (scheme cxr); the shallow forms
 * (car/cdr/caar/cadr/cdar/cddr) stay in creme_register_base_builtins. */
void creme_register_cxr_builtins(VM *vm) {
  creme_register_builtin(vm, "caaar", bi_caaar);
  creme_register_builtin(vm, "caadr", bi_caadr);
  creme_register_builtin(vm, "cadar", bi_cadar);
  creme_register_builtin(vm, "caddr", bi_caddr);
  creme_register_builtin(vm, "cdaar", bi_cdaar);
  creme_register_builtin(vm, "cdadr", bi_cdadr);
  creme_register_builtin(vm, "cddar", bi_cddar);
  creme_register_builtin(vm, "cdddr", bi_cdddr);
  creme_register_builtin(vm, "caaaar", bi_caaaar);
  creme_register_builtin(vm, "caaadr", bi_caaadr);
  creme_register_builtin(vm, "caadar", bi_caadar);
  creme_register_builtin(vm, "caaddr", bi_caaddr);
  creme_register_builtin(vm, "cadaar", bi_cadaar);
  creme_register_builtin(vm, "cadadr", bi_cadadr);
  creme_register_builtin(vm, "caddar", bi_caddar);
  creme_register_builtin(vm, "cadddr", bi_cadddr);
  creme_register_builtin(vm, "cdaaar", bi_cdaaar);
  creme_register_builtin(vm, "cdaadr", bi_cdaadr);
  creme_register_builtin(vm, "cdadar", bi_cdadar);
  creme_register_builtin(vm, "cdaddr", bi_cdaddr);
  creme_register_builtin(vm, "cddaar", bi_cddaar);
  creme_register_builtin(vm, "cddadr", bi_cddadr);
  creme_register_builtin(vm, "cdddar", bi_cdddar);
  creme_register_builtin(vm, "cddddr", bi_cddddr);
}

/* (scheme complex) */
void creme_register_complex_builtins(VM *vm) {
  creme_register_builtin(vm, "complex?", bi_complex_p);
  creme_register_builtin(vm, "make-rectangular", bi_make_rectangular);
  creme_register_builtin(vm, "make-polar", bi_make_polar);
  creme_register_builtin(vm, "real-part", bi_real_part);
  creme_register_builtin(vm, "imag-part", bi_imag_part);
  creme_register_builtin(vm, "magnitude", bi_magnitude);
  creme_register_builtin(vm, "angle", bi_angle);
}

/* char/string case-folding + char classification. NOTE: string-upcase,
 * string-downcase, and string-foldcase are NOT registered here -- they
 * live in strings.c's own register function, not builtins.c, so there is
 * nothing to move for them. */
void creme_register_char_builtins(VM *vm) {
  creme_register_builtin(vm, "char-downcase", bi_char_downcase);
  creme_register_builtin(vm, "char-upcase", bi_char_upcase);
  creme_register_builtin(vm, "char-foldcase", bi_char_foldcase);
  creme_register_builtin(vm, "digit-value", bi_digit_value);
  creme_register_builtin(vm, "char-alphabetic?", bi_char_alphabetic_p);
  creme_register_builtin(vm, "char-numeric?", bi_char_numeric_p);
  creme_register_builtin(vm, "char-whitespace?", bi_char_whitespace_p);
  creme_register_builtin(vm, "char-upper-case?", bi_char_upper_case_p);
  creme_register_builtin(vm, "char-lower-case?", bi_char_lower_case_p);
  creme_register_builtin(vm, "char-ci=?", bi_char_ci_eq);
  creme_register_builtin(vm, "char-ci<?", bi_char_ci_lt);
  creme_register_builtin(vm, "char-ci>?", bi_char_ci_gt);
  creme_register_builtin(vm, "char-ci<=?", bi_char_ci_le);
  creme_register_builtin(vm, "char-ci>=?", bi_char_ci_ge);
  creme_register_builtin(vm, "string-ci=?", bi_string_ci_eq);
  creme_register_builtin(vm, "string-ci<?", bi_string_ci_lt);
  creme_register_builtin(vm, "string-ci>?", bi_string_ci_gt);
  creme_register_builtin(vm, "string-ci<=?", bi_string_ci_le);
  creme_register_builtin(vm, "string-ci>=?", bi_string_ci_ge);
}

/* (scheme write). write-simple reuses bi_write directly -- its
 * contract (never emit datum labels) is exactly what plain `write`
 * already does. write-shared is its own bi_write_shared (above): a
 * genuine two-pass, cycle-safe #n=/#n# writer -- NOT an alias to
 * `write`, since write_value's own T_PAIR case has no cycle guard and
 * would infinite-loop on a circular argument. */
void creme_register_write_builtins(VM *vm) {
  creme_register_builtin(vm, "display", bi_display);
  creme_register_builtin(vm, "write", bi_write);
  creme_register_builtin(vm, "write-simple", bi_write);
  creme_register_builtin(vm, "write-shared", bi_write_shared);
}

/* (scheme process-context). NOTE: emergency-exit is not registered
 * anywhere in builtins.c (or the rest of icecreme) -- only exit exists. The
 * native family (process_context.cr) merges ProcessLibrary (command-line)
 * and EnvVars (get-environment-variable/-variables) into this SAME
 * family, so both are registered here too -- not just under their own
 * "process"/"env" families -- otherwise a script importing ONLY (scheme
 * process-context), with neither (creme process) nor (creme env), would
 * see them come up unbound under icecreme even though they're genuinely
 * ported. */
void creme_register_process_context_builtins(VM *vm) {
  creme_register_builtin(vm, "exit", bi_exit);
  creme_register_builtin(vm, "command-line", bi_command_line);
  creme_register_builtin(vm, "get-environment-variable", bi_get_environment_variable);
  creme_register_builtin(vm, "get-environment-variables", bi_get_environment_variables);
}

/* (scheme lazy): force/promise?/make-promise -- delay/delay-force
 * compile straight to the MakePromise op (see bi_force's own comment),
 * so this is the library's whole runtime surface. */
void creme_register_lazy_builtins(VM *vm) {
  creme_register_builtin(vm, "force", bi_force);
  creme_register_builtin(vm, "promise?", bi_promise_p);
  creme_register_builtin(vm, "make-promise", bi_make_promise);
}

/* (scheme inexact) plus flonum->bits/bits->flonum. */
void creme_register_math_builtins(VM *vm) {
  creme_register_builtin(vm, "flonum->bits", bi_flonum_to_bits);
  creme_register_builtin(vm, "bits->flonum", bi_bits_to_flonum);
  creme_register_builtin(vm, "sin", bi_sin);
  creme_register_builtin(vm, "cos", bi_cos);
  creme_register_builtin(vm, "tan", bi_tan);
  creme_register_builtin(vm, "asin", bi_asin);
  creme_register_builtin(vm, "acos", bi_acos);
  creme_register_builtin(vm, "atan", bi_atan);
  creme_register_builtin(vm, "log", bi_log);
  creme_register_builtin(vm, "exp", bi_exp);
  creme_register_builtin(vm, "log2", bi_log2);
  creme_register_builtin(vm, "log10", bi_log10);
  creme_register_builtin(vm, "atan2", bi_atan2);
  creme_register_builtin(vm, "pow", bi_pow);
  creme_register_builtin(vm, "hypot", bi_hypot);
}

/* Introspection-ish builtins. NOTE: library-exports is NOT registered
 * here -- it lives in bootstrap.c's own register function.
 * stdout-tty?/stdin-tty? moved to creme_register_term_builtins (term.c) --
 * terminal-related, not general introspection. */
void creme_register_introspection_builtins(VM *vm) {
  creme_register_builtin(vm, "gensym", bi_gensym);
  creme_register_builtin(vm, "runtime", bi_runtime);
  creme_register_builtin(vm, "bound-names", bi_bound_names);
  creme_register_builtin(vm, "macro?", bi_macro_p);
  creme_register_builtin(vm, "record-fields", bi_record_fields);
}

/* (scheme file). NOTE: delete-file, file-read, and file-write are NOT
 * registered here -- they live in bootstrap.c's own register function
 * (see its comment "file-read/file-write/delete-file already live in
 * ..."), so there is nothing to move for them here. */
void creme_register_file_builtins(VM *vm) {
  creme_register_builtin(vm, "file-exists?", bi_file_exists_p);
  creme_register_builtin(vm, "open-input-file", bi_open_input_file);
  creme_register_builtin(vm, "open-output-file", bi_open_output_file);
  creme_register_builtin(vm, "open-binary-input-file", bi_open_binary_input_file);
  creme_register_builtin(vm, "open-binary-output-file", bi_open_binary_output_file);
  creme_register_builtin(vm, "call-with-input-file", bi_call_with_input_file);
  creme_register_builtin(vm, "call-with-output-file", bi_call_with_output_file);
  creme_register_builtin(vm, "with-input-from-file", bi_with_input_from_file);
  creme_register_builtin(vm, "with-output-to-file", bi_with_output_to_file);
  creme_register_builtin(vm, "file-append", bi_file_append);
  creme_register_builtin(vm, "file-lines", bi_file_lines);
  creme_register_builtin(vm, "file-size", bi_file_size);
  creme_register_builtin(vm, "current-directory", bi_current_directory);
}

/* (creme env)'s full accessor/mutator set -- native Crystal groups all
 * four under one "env" family (src/creme/modules/creme/env.cr), so all
 * four are registered here together, matching that grouping exactly
 * (get-environment-variables lives in bi_get_environment_variables,
 * above, alongside process-context's own copy -- see
 * creme_register_process_context_builtins and main.c's
 * creme_register_required_builtins for why both registration sites exist).
 * environment-variable-set? has no icecreme-side implementation yet. */
void creme_register_env_builtins(VM *vm) {
  creme_register_builtin(vm, "get-environment-variable", bi_get_environment_variable);
  creme_register_builtin(vm, "get-environment-variables", bi_get_environment_variables);
  creme_register_builtin(vm, "set-environment-variable!", bi_set_environment_variable);
  creme_register_builtin(vm, "delete-environment-variable!", bi_delete_environment_variable);
}

void creme_register_base_builtins(VM *vm) {
  creme_init_current_ports(vm); /* must exist before this function's own current-output-port/current-input-port intern block, below */
  creme_register_builtin(vm, "features", bi_features);
  creme_register_builtin(vm, "make-vector", bi_make_vector);
  creme_register_builtin(vm, "current-second", bi_current_second);
  creme_register_builtin(vm, "sqrt", bi_sqrt);
  creme_register_builtin(vm, "nan?", bi_nan_p);
  creme_register_builtin(vm, "infinite?", bi_infinite_p);
  creme_register_builtin(vm, "finite?", bi_finite_p);
  creme_register_builtin(vm, "random-real", bi_random_real);
  creme_register_builtin(vm, "random-integer", bi_random_integer);
  creme_register_builtin(vm, "random-seed!", bi_random_seed_bang);
  creme_register_builtin(vm, "random-choice", bi_random_choice);
  creme_register_builtin(vm, "random-shuffle", bi_random_shuffle);
  /* pi/e are value constants, not procedures -- interned directly into
   * the global table (mirroring creme_register_builtin's own two-line
   * shape) rather than through a BuiltinFn, matching how native's own
   * register_library block does `env.define("pi", ...)` alongside its
   * register_module calls (see creme/math.cr). */
  {
    int pi_slot = creme_global_intern(vm, "pi", 2);
    vm->globals[pi_slot].value = v_float(M_PI);
    vm->globals[pi_slot].bound = 1;
    int e_slot = creme_global_intern(vm, "e", 1);
    vm->globals[e_slot].value = v_float(M_E);
    vm->globals[e_slot].bound = 1;
  }
  creme_register_builtin(vm, "newline", bi_newline);
  creme_register_builtin(vm, "open-output-string", bi_open_output_string);
  creme_register_builtin(vm, "get-output-string", bi_get_output_string);
  creme_register_builtin(vm, "string-length", bi_string_length);
  creme_register_builtin(vm, "write-string", bi_write_string);
  creme_register_builtin(vm, "write-char", bi_write_char);
  creme_register_builtin(vm, "reverse", bi_reverse);
  creme_register_builtin(vm, "length", bi_length);
  /* Genuine T_PARAMETER values, not builtins -- interned directly
   * (pi/e-style, see that block above) so parameterize can target them.
   * creme_init_current_ports (called once per VM, before this point --
   * main.c for the top-level VM, creme_new_child_vm for a spawned actor's
   * own VM) already built vm->current_output_param/
   * vm->current_input_param. */
  {
    int cop_slot = creme_global_intern(vm, "current-output-port", 20);
    vm->globals[cop_slot].value = v_parameter(vm->current_output_param);
    vm->globals[cop_slot].bound = 1;
    int cip_slot = creme_global_intern(vm, "current-input-port", 19);
    vm->globals[cip_slot].value = v_parameter(vm->current_input_param);
    vm->globals[cip_slot].bound = 1;
  }
  creme_register_builtin(vm, "open-input-string", bi_open_input_string);
  creme_register_builtin(vm, "port?", bi_port_p);
  creme_register_builtin(vm, "input-port?", bi_input_port_p);
  creme_register_builtin(vm, "output-port?", bi_output_port_p);
  creme_register_builtin(vm, "eof-object", bi_eof_object);
  creme_register_builtin(vm, "eof-object?", bi_eof_object_p);
  creme_register_builtin(vm, "close-port", bi_close_port);
  creme_register_builtin(vm, "flush-output-port", bi_flush_output_port);
  creme_register_builtin(vm, "close-input-port", bi_close_port);
  creme_register_builtin(vm, "close-output-port", bi_close_port);
  creme_register_builtin(vm, "read-char", bi_read_char);
  creme_register_builtin(vm, "peek-char", bi_peek_char);
  creme_register_builtin(vm, "read-line", bi_read_line);
  creme_register_builtin(vm, "read-string", bi_read_string);
  creme_register_builtin(vm, "char-ready?", bi_char_ready_p);
  creme_register_builtin(vm, "read", bi_read);

  creme_register_builtin(vm, "not", bi_not);
  creme_register_builtin(vm, "pair?", bi_pair_p);
  creme_register_builtin(vm, "null?", bi_null_p);
  creme_register_builtin(vm, "list?", bi_list_p);
  creme_register_builtin(vm, "boolean?", bi_boolean_p);
  creme_register_builtin(vm, "symbol?", bi_symbol_p);
  creme_register_builtin(vm, "string?", bi_string_p);
  creme_register_builtin(vm, "vector?", bi_vector_p);
  creme_register_builtin(vm, "vector-ref", bi_vector_ref);
  creme_register_builtin(vm, "vector-set!", bi_vector_set);
  creme_register_builtin(vm, "vector-length", bi_vector_length);
  creme_register_builtin(vm, "string-ref", bi_string_ref);
  creme_register_builtin(vm, "string-set!", bi_string_set);
  creme_register_builtin(vm, "bytevector-u8-ref", bi_bytevector_u8_ref);
  creme_register_builtin(vm, "bytevector-u8-set!", bi_bytevector_u8_set);
  creme_register_builtin(vm, "char?", bi_char_p);
  creme_register_builtin(vm, "procedure?", bi_procedure_p);
  creme_register_builtin(vm, "number?", bi_number_p);
  creme_register_builtin(vm, "real?", bi_real_p);
  creme_register_builtin(vm, "integer?", bi_integer_p);
  creme_register_builtin(vm, "exact?", bi_exact_p);
  creme_register_builtin(vm, "inexact?", bi_inexact_p);
  creme_register_builtin(vm, "exact-integer?", bi_exact_integer_p);
  creme_register_builtin(vm, "rational?", bi_rational_p);
  creme_register_builtin(vm, "numerator", bi_numerator);
  creme_register_builtin(vm, "denominator", bi_denominator);
  creme_register_builtin(vm, "eq?", bi_eq_p);
  creme_register_builtin(vm, "eqv?", bi_eqv_p);
  creme_register_builtin(vm, "equal?", bi_equal_p);

  creme_register_builtin(vm, "zero?", bi_zero_p);
  creme_register_builtin(vm, "positive?", bi_positive_p);
  creme_register_builtin(vm, "negative?", bi_negative_p);
  creme_register_builtin(vm, "odd?", bi_odd_p);
  creme_register_builtin(vm, "even?", bi_even_p);
  creme_register_builtin(vm, "abs", bi_abs);
  creme_register_builtin(vm, "square", bi_square);
  creme_register_builtin(vm, "min", bi_min);
  creme_register_builtin(vm, "max", bi_max);
  creme_register_builtin(vm, "round", bi_round);
  creme_register_builtin(vm, "floor", bi_floor);
  creme_register_builtin(vm, "ceiling", bi_ceiling);
  creme_register_builtin(vm, "truncate", bi_truncate);
  creme_register_builtin(vm, "exact", bi_exact);
  creme_register_builtin(vm, "inexact", bi_inexact);
  creme_register_builtin(vm, "exact->inexact", bi_inexact);
  creme_register_builtin(vm, "inexact->exact", bi_exact);

  creme_register_builtin(vm, "car", bi_car);
  creme_register_builtin(vm, "cdr", bi_cdr);
  creme_register_builtin(vm, "set-car!", bi_set_car_bang);
  creme_register_builtin(vm, "set-cdr!", bi_set_cdr_bang);
  creme_register_builtin(vm, "caar", bi_caar);
  creme_register_builtin(vm, "cadr", bi_cadr);
  creme_register_builtin(vm, "cdar", bi_cdar);
  creme_register_builtin(vm, "cddr", bi_cddr);
  creme_register_builtin(vm, "cons", bi_cons);
  creme_register_builtin(vm, "list", bi_list);
  creme_register_builtin(vm, "cons*", bi_cons_star);
  creme_register_builtin(vm, "append", bi_append);
  creme_register_builtin(vm, "list-tail", bi_list_tail);
  creme_register_builtin(vm, "list-ref", bi_list_ref);
  creme_register_builtin(vm, "list-set!", bi_list_set);
  creme_register_builtin(vm, "make-list", bi_make_list);
  creme_register_builtin(vm, "list-copy", bi_list_copy);
  creme_register_builtin(vm, "last-pair", bi_last_pair);
  creme_register_builtin(vm, "assoc", bi_assoc);
  creme_register_builtin(vm, "assq", bi_assq);
  creme_register_builtin(vm, "assv", bi_assq);
  creme_register_builtin(vm, "member", bi_member);
  creme_register_builtin(vm, "memq", bi_memq);
  creme_register_builtin(vm, "memv", bi_memq);

  creme_register_builtin(vm, "apply", bi_apply);
  creme_register_builtin(vm, "map", bi_map);
  creme_register_builtin(vm, "for-each", bi_for_each);
  creme_register_builtin(vm, "string-for-each", bi_string_for_each);
  creme_register_builtin(vm, "filter", bi_filter);
  creme_register_builtin(vm, "values", bi_values);
  creme_register_builtin(vm, "call-with-values", bi_call_with_values);
  creme_register_builtin(vm, "dynamic-wind", bi_dynamic_wind);
  creme_register_builtin(vm, "call/cc", bi_call_cc);
  creme_register_builtin(vm, "call-with-current-continuation", bi_call_cc);

  creme_register_builtin(vm, "string-append", bi_string_append);
  creme_register_builtin(vm, "substring", bi_substring);
  creme_register_builtin(vm, "string-copy", bi_string_copy);
  creme_register_builtin(vm, "string->list", bi_string_to_list);
  creme_register_builtin(vm, "list->string", bi_list_to_string);
  creme_register_builtin(vm, "make-string", bi_make_string);
  creme_register_builtin(vm, "string", bi_string_ctor);
  creme_register_builtin(vm, "string=?", bi_string_eq);
  creme_register_builtin(vm, "string<?", bi_string_lt);
  creme_register_builtin(vm, "string>?", bi_string_gt);
  creme_register_builtin(vm, "string<=?", bi_string_le);
  creme_register_builtin(vm, "string>=?", bi_string_ge);
  creme_register_builtin(vm, "symbol=?", bi_symbol_eq);
  creme_register_builtin(vm, "boolean=?", bi_boolean_eq);
  creme_register_builtin(vm, "string-map", bi_string_map);
  creme_register_builtin(vm, "string-copy!", bi_string_copy_bang);
  creme_register_builtin(vm, "string-fill!", bi_string_fill_bang);
  creme_register_builtin(vm, "string->vector", bi_string_to_vector);
  creme_register_builtin(vm, "vector->string", bi_vector_to_string);
  creme_register_builtin(vm, "string->number", bi_string_to_number);
  creme_register_builtin(vm, "number->string", bi_number_to_string);
  creme_register_builtin(vm, "string->symbol", bi_string_to_symbol);
  creme_register_builtin(vm, "symbol->string", bi_symbol_to_string);
  creme_register_builtin(vm, "char->integer", bi_char_to_integer);
  creme_register_builtin(vm, "integer->char", bi_integer_to_char);
  creme_register_builtin(vm, "char=?", bi_char_eq);
  creme_register_builtin(vm, "char<?", bi_char_lt);
  creme_register_builtin(vm, "char>?", bi_char_gt);
  creme_register_builtin(vm, "char<=?", bi_char_le);
  creme_register_builtin(vm, "char>=?", bi_char_ge);

  creme_register_builtin(vm, "vector", bi_vector);
  creme_register_builtin(vm, "vector->list", bi_vector_to_list);
  creme_register_builtin(vm, "list->vector", bi_list_to_vector);
  creme_register_builtin(vm, "vector-map", bi_vector_map);
  creme_register_builtin(vm, "vector-for-each", bi_vector_for_each);
  creme_register_builtin(vm, "vector-copy", bi_vector_copy);
  creme_register_builtin(vm, "vector-copy!", bi_vector_copy_bang);
  creme_register_builtin(vm, "vector-fill!", bi_vector_fill);
  creme_register_builtin(vm, "vector-append", bi_vector_append);

  creme_register_builtin(vm, "make-bytevector", bi_make_bytevector);
  creme_register_builtin(vm, "bytevector", bi_bytevector);
  creme_register_builtin(vm, "bytevector-length", bi_bytevector_length);
  creme_register_builtin(vm, "bytevector?", bi_bytevector_p);
  creme_register_builtin(vm, "bytevector-copy", bi_bytevector_copy);
  creme_register_builtin(vm, "bytevector-copy!", bi_bytevector_copy_bang);
  creme_register_builtin(vm, "bytevector-append", bi_bytevector_append);
  creme_register_builtin(vm, "utf8->string", bi_utf8_to_string);
  creme_register_builtin(vm, "string->utf8", bi_string_to_utf8);
  creme_register_builtin(vm, "open-input-bytevector", bi_open_input_bytevector);
  creme_register_builtin(vm, "open-output-bytevector", bi_open_output_bytevector);
  creme_register_builtin(vm, "get-output-bytevector", bi_get_output_bytevector);
  creme_register_builtin(vm, "binary-port?", bi_binary_port_p);
  creme_register_builtin(vm, "textual-port?", bi_textual_port_p);
  creme_register_builtin(vm, "input-port-open?", bi_input_port_open_p);
  creme_register_builtin(vm, "output-port-open?", bi_output_port_open_p);
  creme_register_builtin(vm, "read-u8", bi_read_u8);
  creme_register_builtin(vm, "peek-u8", bi_peek_u8);
  creme_register_builtin(vm, "u8-ready?", bi_char_ready_p);
  creme_register_builtin(vm, "write-u8", bi_write_u8);
  creme_register_builtin(vm, "read-bytevector", bi_read_bytevector);
  creme_register_builtin(vm, "read-bytevector!", bi_read_bytevector_bang);
  creme_register_builtin(vm, "write-bytevector", bi_write_bytevector);
  creme_register_builtin(vm, "call-with-port", bi_call_with_port);

  creme_register_builtin(vm, "error", bi_error);
  creme_register_builtin(vm, "raise", bi_raise);
  creme_register_builtin(vm, "raise-continuable", bi_raise_continuable);
  creme_register_builtin(vm, "with-exception-handler", bi_with_exception_handler);
  creme_register_builtin(vm, "error-object?", bi_error_object_p);
  creme_register_builtin(vm, "error-object-message", bi_error_object_message);
  creme_register_builtin(vm, "error-object-irritants", bi_error_object_irritants);
  creme_register_builtin(vm, "read-error?", bi_read_error_p);
  creme_register_builtin(vm, "file-error?", bi_file_error_p);
  creme_register_builtin(vm, "make-parameter", bi_make_parameter);
  creme_register_builtin(vm, "quotient", bi_quotient);
  creme_register_builtin(vm, "remainder", bi_remainder);
  creme_register_builtin(vm, "modulo", bi_modulo);
  creme_register_builtin(vm, "truncate-quotient", bi_quotient);
  creme_register_builtin(vm, "truncate-remainder", bi_remainder);
  creme_register_builtin(vm, "floor-quotient", bi_floor_quotient);
  creme_register_builtin(vm, "floor-remainder", bi_modulo);
  creme_register_builtin(vm, "truncate/", bi_truncate_slash);
  creme_register_builtin(vm, "floor/", bi_floor_slash);
  creme_register_builtin(vm, "gcd", bi_gcd);
  creme_register_builtin(vm, "lcm", bi_lcm);
  creme_register_builtin(vm, "expt", bi_expt);
  creme_register_builtin(vm, "exact-integer-sqrt", bi_exact_integer_sqrt);
  creme_register_builtin(vm, "+", bi_plus);
  creme_register_builtin(vm, "-", bi_minus);
  creme_register_builtin(vm, "*", bi_star);
  creme_register_builtin(vm, "/", bi_slash);
  creme_register_builtin(vm, "<", bi_num_lt);
  creme_register_builtin(vm, ">", bi_num_gt);
  creme_register_builtin(vm, "<=", bi_num_le);
  creme_register_builtin(vm, ">=", bi_num_ge);
  creme_register_builtin(vm, "=", bi_num_eq);
  creme_register_builtin(vm, "current-time", bi_current_time);
  creme_register_builtin(vm, "time-difference", bi_time_difference);
  creme_register_builtin(vm, "time-add", bi_time_add);
  creme_register_builtin(vm, "time-year", bi_time_year);
  creme_register_builtin(vm, "time-month", bi_time_month);
  creme_register_builtin(vm, "time-day", bi_time_day);
  creme_register_builtin(vm, "time-hour", bi_time_hour);
  creme_register_builtin(vm, "time-minute", bi_time_minute);
  creme_register_builtin(vm, "time-second", bi_time_second);
  creme_register_builtin(vm, "time->string", bi_time_to_string);
  creme_register_builtin(vm, "string->time", bi_string_to_time);
  creme_register_builtin(vm, "current-jiffy", bi_current_jiffy);
  creme_register_builtin(vm, "jiffies-per-second", bi_jiffies_per_second);
}
