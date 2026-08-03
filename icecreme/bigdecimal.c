/* (creme bigdecimal) — see bigdecimal.h. A port of
 * src/creme/modules/creme/big_decimal.cr: arbitrary-precision EXACT
 * decimal arithmetic, matching Crystal's own `require "big"` (standard
 * library, not an external shard) BigDecimal semantics for what this
 * project's own spec suite (spec/scheme/modules/creme/big_decimal_spec.cr)
 * actually exercises.
 *
 * Represented here as (mantissa: mpz_t, scale: int >= 0), meaning the
 * value is mantissa * 10^-scale -- a small hand-rolled type on top of
 * GMP's arbitrary-precision INTEGER type (already linked, used for
 * T_RATIONAL), Java-BigDecimal-style. Deliberately NOT GMP's own mpf_t:
 * that's arbitrary-precision BINARY floating point, not exact base-10
 * decimal (0.1 has no exact binary representation), so reusing it would
 * silently drift from Crystal's own exact-decimal semantics -- an
 * integer mantissa + a decimal scale is exact by construction instead.
 *
 * Unlike native's own SchemeBigDecimal, this is a standalone boxed type
 * (BOX_KIND_BIGDECIMAL), never hooked into the numeric tower -- matching
 * native exactly: SchemeBigDecimal is a plain SchemeBaseValue that +/-/
 * etc. (num_add and friends) never touch, so no numeric-tower promotion
 * work is needed here either, just these 15 standalone procedures.
 *
 * Division is the one genuinely approximate operation: native's own
 * BigDecimal#/ computes to some internal working precision then
 * normalizes. This computes to `max(scaleA, scaleB) + 20` extra decimal
 * digits (round-half-away-from-zero), then trims trailing zero digits
 * back down to scale 0 -- exact for the terminating-decimal cases this
 * project's own spec suite exercises (6/2 = "3.0", not a 22-digit
 * string of trailing zeros), and merely a fixed (not infinite)
 * precision, not silently wrong, for a genuinely repeating quotient
 * (1/3 and the like) -- nothing here exercises that case. */
#include <ctype.h>
#include <gc.h>
#include <stdio.h>
#include <string.h>

#include "bigdecimal.h"
#include "embed.h"

typedef struct {
  mpz_t mantissa;
  int scale; /* always >= 0 -- value = mantissa * 10^-scale */
} BigDecimal;

static BigDecimal *bd_new(void) {
  BigDecimal *bd = GC_MALLOC(sizeof(BigDecimal));
  mpz_init(bd->mantissa);
  bd->scale = 0;
  return bd;
}

static Value v_bigdecimal(BigDecimal *bd) { return v_box(bd, BOX_KIND_BIGDECIMAL); }

static BigDecimal *bigdecimal_arg(Value v, const char *who) {
  return creme_arg_box(&v, 1, 0, BOX_KIND_BIGDECIMAL, who);
}

/* Parses a plain decimal literal: [sign] digits ['.' digits]. No
 * exponent notation -- not part of what this project's own spec suite
 * exercises, a narrower, deliberate cut. Returns 0 (and leaves `out`
 * unspecified) on anything else, matching native's own "invalid
 * decimal" error on a malformed string. */
static int bd_parse(const char *s, int len, BigDecimal *out) {
  int i = 0;
  int neg = 0;
  if (i < len && (s[i] == '+' || s[i] == '-')) {
    neg = (s[i] == '-');
    i++;
  }
  int int_start = i;
  int int_digits = 0;
  while (i < len && isdigit((unsigned char)s[i])) {
    i++;
    int_digits++;
  }
  int has_dot = 0;
  int frac_digits = 0;
  int frac_start = 0;
  if (i < len && s[i] == '.') {
    has_dot = 1;
    i++;
    frac_start = i;
    while (i < len && isdigit((unsigned char)s[i])) i++;
    frac_digits = i - frac_start;
  }
  (void)has_dot;
  if (i != len) return 0; /* trailing junk */
  int total_digits = int_digits + frac_digits;
  if (total_digits == 0) return 0; /* just a sign, or empty */

  char *digits_buf = GC_MALLOC((size_t)(total_digits + 2));
  int di = 0;
  if (neg) digits_buf[di++] = '-';
  for (int k = int_start; k < int_start + int_digits; k++) digits_buf[di++] = s[k];
  for (int k = frac_start; k < frac_start + frac_digits; k++) digits_buf[di++] = s[k];
  digits_buf[di] = '\0';

  if (mpz_set_str(out->mantissa, digits_buf, 10) != 0) return 0;
  out->scale = frac_digits;
  return 1;
}

/* Scales both mantissas up to the larger of the two scales so they're
 * directly comparable/addable -- out_a/out_b are freshly mpz_init'd,
 * caller's responsibility to mpz_clear. */
static void bd_align(const BigDecimal *a, const BigDecimal *b, mpz_t out_a, mpz_t out_b, int *out_scale) {
  int scale = a->scale > b->scale ? a->scale : b->scale;
  mpz_init(out_a);
  mpz_init(out_b);
  mpz_t pow;
  mpz_init(pow);
  if (a->scale < scale) {
    mpz_ui_pow_ui(pow, 10, (unsigned long)(scale - a->scale));
    mpz_mul(out_a, a->mantissa, pow);
  } else {
    mpz_set(out_a, a->mantissa);
  }
  if (b->scale < scale) {
    mpz_ui_pow_ui(pow, 10, (unsigned long)(scale - b->scale));
    mpz_mul(out_b, b->mantissa, pow);
  } else {
    mpz_set(out_b, b->mantissa);
  }
  mpz_clear(pow);
  *out_scale = scale;
}

static int bd_compare(BigDecimal *a, BigDecimal *b) {
  mpz_t na, nb;
  int scale;
  bd_align(a, b, na, nb, &scale);
  int cmp = mpz_cmp(na, nb);
  mpz_clear(na);
  mpz_clear(nb);
  return cmp < 0 ? -1 : (cmp > 0 ? 1 : 0);
}

/* Formats mantissa*10^-scale as a decimal string, ALWAYS with at least
 * one fractional digit -- matches Crystal's own BigDecimal#to_s exactly
 * (a scale-0 result like 5-2 still prints "3.0", not "3"; see the
 * spec's own expectations). Left-pads the digit string with zeros first
 * so the decimal point always has something to its left (e.g. mantissa
 * 5, scale 2 -> "0.05"), then splits it at `scale` digits from the
 * right. */
static char *bd_to_string(const BigDecimal *bd, int *out_len) {
  char *mantissa_str = mpz_get_str(NULL, 10, bd->mantissa);
  int neg = (mantissa_str[0] == '-');
  const char *digits = neg ? mantissa_str + 1 : mantissa_str;
  int ndigits = (int)strlen(digits);

  int scale = bd->scale;
  int min_digits = scale + 1;
  int pad = min_digits > ndigits ? min_digits - ndigits : 0;
  int padded_len = ndigits + pad;

  char *padded = GC_MALLOC((size_t)padded_len + 1);
  for (int i = 0; i < pad; i++) padded[i] = '0';
  memcpy(padded + pad, digits, (size_t)ndigits);
  padded[padded_len] = '\0';

  int int_len = padded_len - scale;
  int total = (neg ? 1 : 0) + int_len + 1 + (scale > 0 ? scale : 1);
  char *out = GC_MALLOC((size_t)total);
  int p = 0;
  if (neg) out[p++] = '-';
  memcpy(out + p, padded, (size_t)int_len);
  p += int_len;
  out[p++] = '.';
  if (scale > 0) {
    memcpy(out + p, padded + int_len, (size_t)scale);
    p += scale;
  } else {
    out[p++] = '0';
  }
  *out_len = p;
  return out;
}

static Value bi_string_to_bigdecimal(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "string->bigdecimal");
  const char *s;
  int len;
  char intbuf[32];
  if (args[0].tag == T_STR) {
    s = args[0].as.chars;
    len = args[0].aux;
  } else if (args[0].tag == T_INT) {
    len = snprintf(intbuf, sizeof(intbuf), "%lld", (long long)args[0].as.i);
    s = intbuf;
  } else {
    creme_abort("string->bigdecimal: expected string, got a non-string value");
  }
  BigDecimal *bd = bd_new();
  if (!bd_parse(s, len, bd)) creme_abort("string->bigdecimal: invalid decimal '%.*s'", len, s);
  return v_bigdecimal(bd);
}

static Value bi_integer_to_bigdecimal(VM *vm, Value *args, int nargs) {
  (void)vm;
  int64_t n = creme_arg_int(args, nargs, 0, "integer->bigdecimal");
  BigDecimal *bd = bd_new();
  mpz_set_si(bd->mantissa, (long)n);
  bd->scale = 0;
  return v_bigdecimal(bd);
}

static Value bi_bigdecimal_add(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "bigdecimal-add");
  BigDecimal *a = bigdecimal_arg(args[0], "bigdecimal-add");
  BigDecimal *b = bigdecimal_arg(args[1], "bigdecimal-add");
  mpz_t na, nb;
  int scale;
  bd_align(a, b, na, nb, &scale);
  BigDecimal *r = bd_new();
  mpz_add(r->mantissa, na, nb);
  r->scale = scale;
  mpz_clear(na);
  mpz_clear(nb);
  return v_bigdecimal(r);
}

static Value bi_bigdecimal_sub(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "bigdecimal-sub");
  BigDecimal *a = bigdecimal_arg(args[0], "bigdecimal-sub");
  BigDecimal *b = bigdecimal_arg(args[1], "bigdecimal-sub");
  mpz_t na, nb;
  int scale;
  bd_align(a, b, na, nb, &scale);
  BigDecimal *r = bd_new();
  mpz_sub(r->mantissa, na, nb);
  r->scale = scale;
  mpz_clear(na);
  mpz_clear(nb);
  return v_bigdecimal(r);
}

static Value bi_bigdecimal_mul(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "bigdecimal-mul");
  BigDecimal *a = bigdecimal_arg(args[0], "bigdecimal-mul");
  BigDecimal *b = bigdecimal_arg(args[1], "bigdecimal-mul");
  BigDecimal *r = bd_new();
  mpz_mul(r->mantissa, a->mantissa, b->mantissa);
  r->scale = a->scale + b->scale;
  return v_bigdecimal(r);
}

#define BD_DIV_EXTRA_DIGITS 20

static Value bi_bigdecimal_div(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "bigdecimal-div");
  BigDecimal *a = bigdecimal_arg(args[0], "bigdecimal-div");
  BigDecimal *b = bigdecimal_arg(args[1], "bigdecimal-div");
  if (mpz_sgn(b->mantissa) == 0) creme_abort("bigdecimal-div: division by zero");

  int working_scale = (a->scale > b->scale ? a->scale : b->scale) + BD_DIV_EXTRA_DIGITS;
  /* a/b = (A/10^sa)/(B/10^sb) = A*10^sb / (B*10^sa); scaled by 10^S:
   * quotient ~= round(A * 10^(sb - sa + S) / B). exp is always >= 0
   * here since S >= max(sa,sb) >= sa, so sb - sa + S >= sb >= 0. */
  int exp = b->scale - a->scale + working_scale;
  mpz_t numerator, pow, quotient, remainder;
  mpz_init(numerator);
  mpz_init(pow);
  mpz_init(quotient);
  mpz_init(remainder);
  mpz_ui_pow_ui(pow, 10, (unsigned long)exp);
  mpz_mul(numerator, a->mantissa, pow);
  mpz_tdiv_qr(quotient, remainder, numerator, b->mantissa);

  /* Round half away from zero: compare 2*|remainder| to |divisor|. */
  mpz_t abs_rem, abs_b, twice_rem;
  mpz_init(abs_rem);
  mpz_init(abs_b);
  mpz_init(twice_rem);
  mpz_abs(abs_rem, remainder);
  mpz_abs(abs_b, b->mantissa);
  mpz_mul_ui(twice_rem, abs_rem, 2);
  if (mpz_cmp(twice_rem, abs_b) >= 0) {
    if (mpz_sgn(numerator) * mpz_sgn(b->mantissa) >= 0) {
      mpz_add_ui(quotient, quotient, 1);
    } else {
      mpz_sub_ui(quotient, quotient, 1);
    }
  }
  mpz_clear(abs_rem);
  mpz_clear(abs_b);
  mpz_clear(twice_rem);

  /* Trim trailing zero digits back down to scale 0 -- exact for a
   * terminating quotient (e.g. 6/2 ends up "3.0", not 20 zeros). */
  int scale = working_scale;
  mpz_t ten, q, r2;
  mpz_init(ten);
  mpz_init(q);
  mpz_init(r2);
  mpz_set_ui(ten, 10);
  while (scale > 0) {
    mpz_tdiv_qr(q, r2, quotient, ten);
    if (mpz_sgn(r2) != 0) break;
    mpz_set(quotient, q);
    scale--;
  }
  mpz_clear(ten);
  mpz_clear(q);
  mpz_clear(r2);

  BigDecimal *result = bd_new();
  mpz_set(result->mantissa, quotient);
  result->scale = scale;

  mpz_clear(numerator);
  mpz_clear(pow);
  mpz_clear(quotient);
  mpz_clear(remainder);
  return v_bigdecimal(result);
}

static Value bi_bigdecimal_neg(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "bigdecimal-neg");
  BigDecimal *a = bigdecimal_arg(args[0], "bigdecimal-neg");
  BigDecimal *r = bd_new();
  mpz_neg(r->mantissa, a->mantissa);
  r->scale = a->scale;
  return v_bigdecimal(r);
}

static Value bi_bigdecimal_compare(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "bigdecimal-compare");
  BigDecimal *a = bigdecimal_arg(args[0], "bigdecimal-compare");
  BigDecimal *b = bigdecimal_arg(args[1], "bigdecimal-compare");
  return v_int(bd_compare(a, b));
}

static Value bi_bigdecimal_eq(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "bigdecimal=?");
  return v_bool(bd_compare(bigdecimal_arg(args[0], "bigdecimal=?"), bigdecimal_arg(args[1], "bigdecimal=?")) == 0);
}

static Value bi_bigdecimal_lt(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "bigdecimal<?");
  return v_bool(bd_compare(bigdecimal_arg(args[0], "bigdecimal<?"), bigdecimal_arg(args[1], "bigdecimal<?")) < 0);
}

static Value bi_bigdecimal_gt(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "bigdecimal>?");
  return v_bool(bd_compare(bigdecimal_arg(args[0], "bigdecimal>?"), bigdecimal_arg(args[1], "bigdecimal>?")) > 0);
}

static Value bi_bigdecimal_zero_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "bigdecimal-zero?");
  return v_bool(mpz_sgn(bigdecimal_arg(args[0], "bigdecimal-zero?")->mantissa) == 0);
}

static Value bi_bigdecimal_to_string(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "bigdecimal->string");
  BigDecimal *bd = bigdecimal_arg(args[0], "bigdecimal->string");
  int len;
  char *s = bd_to_string(bd, &len);
  return v_str(s, len);
}

static Value bi_bigdecimal_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "bigdecimal?");
  return v_bool(args[0].tag == T_BOX && args[0].aux == BOX_KIND_BIGDECIMAL);
}

void creme_register_bigdecimal_builtins(VM *vm) {
  creme_register_builtin(vm, "string->bigdecimal", bi_string_to_bigdecimal);
  creme_register_builtin(vm, "integer->bigdecimal", bi_integer_to_bigdecimal);
  creme_register_builtin(vm, "bigdecimal-add", bi_bigdecimal_add);
  creme_register_builtin(vm, "bigdecimal-sub", bi_bigdecimal_sub);
  creme_register_builtin(vm, "bigdecimal-mul", bi_bigdecimal_mul);
  creme_register_builtin(vm, "bigdecimal-div", bi_bigdecimal_div);
  creme_register_builtin(vm, "bigdecimal-neg", bi_bigdecimal_neg);
  creme_register_builtin(vm, "bigdecimal-compare", bi_bigdecimal_compare);
  creme_register_builtin(vm, "bigdecimal=?", bi_bigdecimal_eq);
  creme_register_builtin(vm, "bigdecimal<?", bi_bigdecimal_lt);
  creme_register_builtin(vm, "bigdecimal>?", bi_bigdecimal_gt);
  creme_register_builtin(vm, "bigdecimal-zero?", bi_bigdecimal_zero_p);
  creme_register_builtin(vm, "bigdecimal->string", bi_bigdecimal_to_string);
  creme_register_builtin(vm, "bigdecimal?", bi_bigdecimal_p);
}
