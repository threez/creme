/* (creme string) + (creme format) — see strings.h.
 *
 * Output construction goes through sds (vendor/sds, BSD-2-Clause)'s
 * growable string buffer (sdsempty/sdscatlen) rather than hand-rolled
 * malloc/realloc bookkeeping -- the actual find/compare/transform logic is
 * still an ordinary C loop either way (sds has no string-utility API of
 * its own beyond the growable buffer itself). Every
 * sds buffer here is only ever reachable from a plain GC_MALLOC'd Value
 * (via sds_to_value's copy), so sdsalloc.h routes it through GC_MALLOC/
 * GC_REALLOC/GC_FREE instead of libc, same as everything else in icecreme.
 *
 * Every function that returns a string copies its bytes into a fresh
 * buffer, even one that only ever picks out an existing substring
 * (string-trim, string-split's own pieces) — T_STR is mutable
 * (string-set!) as of Group C, so aliasing a source buffer directly
 * (this file's own earlier convention, back when strings were immutable)
 * would let mutating a derived string silently corrupt whatever it was
 * derived from.
 *
 * ASCII-only (upcase/downcase/whitespace) — this prototype's strings are
 * plain bytes throughout (see string-ref's own comment in vm.c), not
 * Unicode-aware, matching every other string operation here. */
#include "builtin_config.h"

#if CREME_WITH_STRING

#include <gc.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "embed.h"
#include "sds.h"
#include "strings.h"

static Value v_gcstr(const char *s, size_t len) {
  char *copy = GC_MALLOC(len ? len : 1);
  memcpy(copy, s, len);
  return v_str(copy, (int)len);
}

static Value sds_to_value(sds buf) {
  Value result = v_gcstr(buf, sdslen(buf));
  sdsfree(buf);
  return result;
}

static int is_ws(char c) {
  return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v';
}

/* -1 if `needle` doesn't occur in `hay`; the empty needle occurs at 0. */
static int find_substring(Value hay, Value needle) {
  int hlen = hay.aux, nlen = needle.aux;
  if (nlen == 0) return 0;
  for (int i = 0; i <= hlen - nlen; i++) {
    if (memcmp(hay.as.chars + i, needle.as.chars, (size_t)nlen) == 0) return i;
  }
  return -1;
}

static Value bi_string_upcase(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) creme_abort("string-upcase: expected a string");
  sds buf = sdsMakeRoomFor(sdsempty(), (size_t)args[0].aux);
  for (int i = 0; i < args[0].aux; i++) {
    char c = args[0].as.chars[i];
    if (c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A');
    buf = sdscatlen(buf, &c, 1);
  }
  return sds_to_value(buf);
}

static Value bi_string_downcase(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) creme_abort("string-downcase: expected a string");
  sds buf = sdsMakeRoomFor(sdsempty(), (size_t)args[0].aux);
  for (int i = 0; i < args[0].aux; i++) {
    char c = args[0].as.chars[i];
    if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
    buf = sdscatlen(buf, &c, 1);
  }
  return sds_to_value(buf);
}

static Value bi_string_trim(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) creme_abort("string-trim: expected a string");
  const char *s = args[0].as.chars;
  int len = args[0].aux, start = 0, end = len;
  while (start < end && is_ws(s[start])) start++;
  while (end > start && is_ws(s[end - 1])) end--;
  /* A genuine copy, not the source buffer offset directly (the header
   * comment above used to say this shares the source buffer -- that was
   * only safe while T_STR was immutable; now that string-set! exists,
   * aliasing here would let mutating the trimmed result also mutate the
   * original string). */
  return v_gcstr(s + start, (size_t)(end - start));
}

static Value bi_string_reverse(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) creme_abort("string-reverse: expected a string");
  int len = args[0].aux;
  sds buf = sdsMakeRoomFor(sdsempty(), (size_t)len);
  for (int i = len - 1; i >= 0; i--) buf = sdscatlen(buf, args[0].as.chars + i, 1);
  return sds_to_value(buf);
}

static Value bi_string_split(VM *vm, Value *args, int nargs) {
  if (nargs < 2 || args[0].tag != T_STR || args[1].tag != T_STR) creme_abort("string-split: expected (string sep)");
  const char *s = args[0].as.chars;
  int slen = args[0].aux;
  const char *sep = args[1].as.chars;
  int seplen = args[1].aux;
  Value *parts = NULL;
  int n = 0, cap = 0;
  if (seplen == 0) {
    parts = GC_MALLOC(sizeof(Value));
    parts[0] = v_gcstr(s, (size_t)slen);
    n = 1;
  } else {
    int start = 0;
    int i = 0;
    while (i <= slen - seplen) {
      if (memcmp(s + i, sep, (size_t)seplen) == 0) {
        if (n >= cap) { cap = cap ? cap * 2 : 8; parts = GC_REALLOC(parts, sizeof(Value) * (size_t)cap); }
        parts[n++] = v_gcstr(s + start, (size_t)(i - start));
        i += seplen;
        start = i;
      } else {
        i++;
      }
    }
    if (n >= cap) { cap = cap ? cap * 2 : 8; parts = GC_REALLOC(parts, sizeof(Value) * (size_t)cap); }
    parts[n++] = v_gcstr(s + start, (size_t)(slen - start));
  }
  Value result = v_nil();
  for (int i = n - 1; i >= 0; i--) result = creme_cons(vm, parts[i], result);
  return result;
}

static Value bi_string_join(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2 || args[1].tag != T_STR) creme_abort("string-join: expected (list sep)");
  sds buf = sdsMakeRoomFor(sdsempty(), 64);
  Value cur = args[0];
  int first = 1;
  while (cur.tag == T_PAIR) {
    if (cur.as.pair->car.tag != T_STR) creme_abort("string-join: expected a list of strings");
    if (!first) buf = sdscatlen(buf, args[1].as.chars, (size_t)args[1].aux);
    first = 0;
    buf = sdscatlen(buf, cur.as.pair->car.as.chars, (size_t)cur.as.pair->car.aux);
    cur = cur.as.pair->cdr;
  }
  return sds_to_value(buf);
}

static Value bi_string_replace(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 3 || args[0].tag != T_STR || args[1].tag != T_STR || args[2].tag != T_STR) {
    creme_abort("string-replace: expected (string from to)");
  }
  const char *s = args[0].as.chars;
  int slen = args[0].aux;
  const char *from = args[1].as.chars;
  int fromlen = args[1].aux;
  sds buf = sdsMakeRoomFor(sdsempty(), (size_t)slen);
  if (fromlen == 0) {
    buf = sdscatlen(buf, s, (size_t)slen);
    return sds_to_value(buf);
  }
  int i = 0;
  while (i < slen) {
    if (i <= slen - fromlen && memcmp(s + i, from, (size_t)fromlen) == 0) {
      buf = sdscatlen(buf, args[2].as.chars, (size_t)args[2].aux);
      i += fromlen;
    } else {
      buf = sdscatlen(buf, s + i, 1);
      i++;
    }
  }
  return sds_to_value(buf);
}

static Value bi_string_translate(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2 || args[0].tag != T_STR) creme_abort("string-translate: expected (string alist)");
  const char *s = args[0].as.chars;
  int slen = args[0].aux;
  sds buf = sdsMakeRoomFor(sdsempty(), (size_t)slen);
  for (int i = 0; i < slen; i++) {
    char c = s[i];
    Value cur = args[1];
    Value replacement = v_nil();
    int found = 0;
    while (cur.tag == T_PAIR) {
      Value pair = cur.as.pair->car;
      if (pair.tag == T_PAIR && pair.as.pair->car.tag == T_CHAR && (char)pair.as.pair->car.as.i == c &&
          pair.as.pair->cdr.tag == T_STR) {
        replacement = pair.as.pair->cdr;
        found = 1;
        break;
      }
      cur = cur.as.pair->cdr;
    }
    if (found) {
      buf = sdscatlen(buf, replacement.as.chars, (size_t)replacement.aux);
    } else {
      buf = sdscatlen(buf, &c, 1);
    }
  }
  return sds_to_value(buf);
}

static Value bi_string_contains_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2 || args[0].tag != T_STR || args[1].tag != T_STR) creme_abort("string-contains?: expected two strings");
  return v_bool(find_substring(args[0], args[1]) >= 0);
}

static Value bi_string_prefix_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2 || args[0].tag != T_STR || args[1].tag != T_STR) creme_abort("string-prefix?: expected two strings");
  int hlen = args[0].aux, nlen = args[1].aux;
  return v_bool(hlen >= nlen && memcmp(args[0].as.chars, args[1].as.chars, (size_t)nlen) == 0);
}

static Value bi_string_suffix_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2 || args[0].tag != T_STR || args[1].tag != T_STR) creme_abort("string-suffix?: expected two strings");
  int hlen = args[0].aux, nlen = args[1].aux;
  return v_bool(hlen >= nlen && memcmp(args[0].as.chars + (hlen - nlen), args[1].as.chars, (size_t)nlen) == 0);
}

static Value bi_string_index_of(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2 || args[0].tag != T_STR || args[1].tag != T_STR) creme_abort("string-index-of: expected two strings");
  int idx = find_substring(args[0], args[1]);
  return idx >= 0 ? v_int(idx) : v_bool(0);
}

static Value bi_string_repeat(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2 || args[0].tag != T_STR || args[1].tag != T_INT) creme_abort("string-repeat: expected (string n)");
  if (args[1].as.i < 0) creme_abort("string-repeat: count must be non-negative");
  sds buf = sdsMakeRoomFor(sdsempty(), (size_t)args[0].aux * (size_t)(args[1].as.i > 0 ? args[1].as.i : 1));
  for (int64_t i = 0; i < args[1].as.i; i++) buf = sdscatlen(buf, args[0].as.chars, (size_t)args[0].aux);
  return sds_to_value(buf);
}

static Value bi_string_pad(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 3 || args[0].tag != T_STR || args[1].tag != T_INT || args[2].tag != T_STR) {
    creme_abort("string-pad: expected (string len pad)");
  }
  if (args[2].aux != 1) creme_abort("string-pad: pad string must be exactly 1 char");
  int64_t target = args[1].as.i;
  int slen = args[0].aux;
  if (slen >= target) return args[0];
  char padc = args[2].as.chars[0];
  sds buf = sdsMakeRoomFor(sdsempty(), (size_t)target);
  for (int64_t i = 0; i < target - slen; i++) buf = sdscatlen(buf, &padc, 1);
  buf = sdscatlen(buf, args[0].as.chars, (size_t)slen);
  return sds_to_value(buf);
}

static Value bi_string_pad_right(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 3 || args[0].tag != T_STR || args[1].tag != T_INT || args[2].tag != T_STR) {
    creme_abort("string-pad-right: expected (string len pad)");
  }
  if (args[2].aux != 1) creme_abort("string-pad-right: pad string must be exactly 1 char");
  int64_t target = args[1].as.i;
  int slen = args[0].aux;
  if (slen >= target) return args[0];
  char padc = args[2].as.chars[0];
  sds buf = sdsMakeRoomFor(sdsempty(), (size_t)target);
  buf = sdscatlen(buf, args[0].as.chars, (size_t)slen);
  for (int64_t i = 0; i < target - slen; i++) buf = sdscatlen(buf, &padc, 1);
  return sds_to_value(buf);
}

/* ---- format ---- */

static sds format_write_display(sds buf, Value v) {
  switch (v.tag) {
  case T_STR:
  case T_SYM:
    return sdscatlen(buf, v.as.chars, (size_t)v.aux);
  case T_INT: {
    char tmp[32];
    int len = snprintf(tmp, sizeof(tmp), "%lld", (long long)v.as.i);
    return sdscatlen(buf, tmp, (size_t)len);
  }
  case T_FLOAT: {
    char tmp[64];
    double f = v.as.f;
    int len = (fabs(f) < 1e15 && f == (double)(int64_t)f) ? snprintf(tmp, sizeof(tmp), "%lld.0", (long long)f)
                                                           : snprintf(tmp, sizeof(tmp), "%.17g", f);
    return sdscatlen(buf, tmp, (size_t)len);
  }
  case T_BOOL:
    return sdscatlen(buf, v.as.b ? "#t" : "#f", 2);
  case T_NIL:
    return sdscatlen(buf, "()", 2);
  case T_CHAR: {
    char c = (char)v.as.i;
    return sdscatlen(buf, &c, 1);
  }
  default:
    return sdscatlen(buf, "#<object>", 9);
  }
}

static void format_int_radix(int64_t n, int radix, char *out, size_t cap) {
  char tmp[80];
  int ti = 0;
  int neg = n < 0;
  uint64_t un = neg ? (uint64_t)(-(n + 1)) + 1 : (uint64_t)n;
  if (un == 0) tmp[ti++] = '0';
  while (un > 0) {
    int d = (int)(un % (uint64_t)radix);
    tmp[ti++] = d < 10 ? (char)('0' + d) : (char)('a' + d - 10);
    un /= (uint64_t)radix;
  }
  int oi = 0;
  if (neg && oi < (int)cap - 1) out[oi++] = '-';
  while (ti > 0 && oi < (int)cap - 1) out[oi++] = tmp[--ti];
  out[oi] = 0;
}

/* SRFI-28-style directive formatting, mirroring format.cr exactly:
 * ~a/~s (this prototype has no separate `write`-with-quoting form, so ~s
 * falls back to ~a's own display rendering), ~c, ~%, ~~, ~d/~x/~o/~b. */
static Value bi_format(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "format");
  if (args[0].tag != T_BOOL) creme_abort("format: expected #t or #f as destination");
  if (args[1].tag != T_STR) creme_abort("format: expected a format string");
  const char *fmt = args[1].as.chars;
  int fmtlen = args[1].aux;
  sds buf = sdsMakeRoomFor(sdsempty(), (size_t)fmtlen);
  int argi = 2;
  int i = 0;
  while (i < fmtlen) {
    char c = fmt[i];
    if (c != '~') {
      buf = sdscatlen(buf, &c, 1);
      i++;
      continue;
    }
    if (i + 1 >= fmtlen) creme_abort("format: dangling '~' at end of format string");
    char directive = fmt[i + 1];
    char lower = (directive >= 'A' && directive <= 'Z') ? (char)(directive - 'A' + 'a') : directive;
    i += 2;
    switch (lower) {
    case '~':
      buf = sdscatlen(buf, "~", 1);
      break;
    case '%':
      buf = sdscatlen(buf, "\n", 1);
      break;
    case 'a':
    case 's':
      if (argi >= nargs) creme_abort("format: not enough arguments for format string");
      buf = format_write_display(buf, args[argi]);
      argi++;
      break;
    case 'c':
      if (argi >= nargs) creme_abort("format: not enough arguments for format string");
      if (args[argi].tag != T_CHAR) creme_abort("format: ~c expected a char");
      {
        char ch = (char)args[argi].as.i;
        buf = sdscatlen(buf, &ch, 1);
      }
      argi++;
      break;
    case 'd':
    case 'x':
    case 'o':
    case 'b': {
      if (argi >= nargs) creme_abort("format: not enough arguments for format string");
      if (args[argi].tag != T_INT) creme_abort("format: expected an integer");
      int base = lower == 'd' ? 10 : lower == 'x' ? 16 : lower == 'o' ? 8 : 2;
      char numbuf[80];
      format_int_radix(args[argi].as.i, base, numbuf, sizeof(numbuf));
      buf = sdscatlen(buf, numbuf, strlen(numbuf));
      argi++;
      break;
    }
    default:
      creme_abort("format: unknown format directive '~%c'", directive);
    }
  }
  if (!args[0].as.b) {
    return sds_to_value(buf);
  }
  fwrite(buf, 1, sdslen(buf), stdout);
  sdsfree(buf);
  return v_nil();
}

void creme_register_string_builtins(VM *vm) {
  creme_register_builtin(vm, "string-upcase", bi_string_upcase);
  creme_register_builtin(vm, "string-downcase", bi_string_downcase);
  /* (scheme char)'s string-foldcase is literally the same as string-downcase
   * (native's own comment: "correct for the ASCII/simple-Unicode range
   * this interpreter otherwise handles") -- same function, second name. */
  creme_register_builtin(vm, "string-foldcase", bi_string_downcase);
  creme_register_builtin(vm, "string-trim", bi_string_trim);
  creme_register_builtin(vm, "string-reverse", bi_string_reverse);
  creme_register_builtin(vm, "string-split", bi_string_split);
  creme_register_builtin(vm, "string-join", bi_string_join);
  creme_register_builtin(vm, "string-replace", bi_string_replace);
  creme_register_builtin(vm, "string-translate", bi_string_translate);
  creme_register_builtin(vm, "string-contains?", bi_string_contains_p);
  creme_register_builtin(vm, "string-prefix?", bi_string_prefix_p);
  creme_register_builtin(vm, "string-suffix?", bi_string_suffix_p);
  creme_register_builtin(vm, "string-index-of", bi_string_index_of);
  creme_register_builtin(vm, "string-repeat", bi_string_repeat);
  creme_register_builtin(vm, "string-pad", bi_string_pad);
  creme_register_builtin(vm, "string-pad-right", bi_string_pad_right);
  creme_register_builtin(vm, "format", bi_format);
}

#endif /* CREME_WITH_STRING */
