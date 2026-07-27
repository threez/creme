/* (creme string) + (creme format) — see strings.h.
 *
 * Per your decision: output construction goes through facil.io's fiobj_str
 * growable buffer (fiobj_str_buf/fiobj_str_write) rather than hand-rolled
 * malloc/realloc bookkeeping — the actual find/compare/transform logic is
 * still an ordinary C loop either way (FIOBJ has no string-utility API of
 * its own beyond the growable buffer itself). Every function that returns
 * a string copies its bytes into a fresh buffer, even one that only ever
 * picks out an existing substring (string-trim, string-split's own
 * pieces) — T_STR is mutable (string-set!) as of Group C, so aliasing a
 * source buffer directly (this file's own earlier convention, back when
 * strings were immutable) would let mutating a derived string silently
 * corrupt whatever it was derived from.
 *
 * ASCII-only (upcase/downcase/whitespace) — this prototype's strings are
 * plain bytes throughout (see string-ref's own comment in vm.c), not
 * Unicode-aware, matching every other string operation here. */
#include <fiobj.h>
#include <gc.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "strings.h"

static Value v_gcstr(const char *s, size_t len) {
  char *copy = GC_MALLOC(len ? len : 1);
  memcpy(copy, s, len);
  return v_str(copy, (int)len);
}

static Value fio_buf_to_value(FIOBJ buf) {
  fio_str_info_s info = fiobj_obj2cstr(buf);
  Value result = v_gcstr(info.data, info.len);
  fiobj_free(buf);
  return result;
}

static int is_ws(char c) {
  return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v';
}

/* -1 if `needle` doesn't occur in `hay`; the empty needle occurs at 0. */
static int find_substring(Value hay, Value needle) {
  int hlen = hay.as.str.len, nlen = needle.as.str.len;
  if (nlen == 0) return 0;
  for (int i = 0; i <= hlen - nlen; i++) {
    if (memcmp(hay.as.str.chars + i, needle.as.str.chars, (size_t)nlen) == 0) return i;
  }
  return -1;
}

static Value bi_string_upcase(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) cvm_abort("string-upcase: expected a string");
  FIOBJ buf = fiobj_str_buf((size_t)args[0].as.str.len);
  for (int i = 0; i < args[0].as.str.len; i++) {
    char c = args[0].as.str.chars[i];
    if (c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A');
    fiobj_str_write(buf, &c, 1);
  }
  return fio_buf_to_value(buf);
}

static Value bi_string_downcase(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) cvm_abort("string-downcase: expected a string");
  FIOBJ buf = fiobj_str_buf((size_t)args[0].as.str.len);
  for (int i = 0; i < args[0].as.str.len; i++) {
    char c = args[0].as.str.chars[i];
    if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
    fiobj_str_write(buf, &c, 1);
  }
  return fio_buf_to_value(buf);
}

static Value bi_string_trim(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) cvm_abort("string-trim: expected a string");
  const char *s = args[0].as.str.chars;
  int len = args[0].as.str.len, start = 0, end = len;
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
  if (nargs < 1 || args[0].tag != T_STR) cvm_abort("string-reverse: expected a string");
  int len = args[0].as.str.len;
  FIOBJ buf = fiobj_str_buf((size_t)len);
  for (int i = len - 1; i >= 0; i--) fiobj_str_write(buf, args[0].as.str.chars + i, 1);
  return fio_buf_to_value(buf);
}

static Value bi_string_split(VM *vm, Value *args, int nargs) {
  if (nargs < 2 || args[0].tag != T_STR || args[1].tag != T_STR) cvm_abort("string-split: expected (string sep)");
  const char *s = args[0].as.str.chars;
  int slen = args[0].as.str.len;
  const char *sep = args[1].as.str.chars;
  int seplen = args[1].as.str.len;
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
  for (int i = n - 1; i >= 0; i--) result = cvm_cons(vm, parts[i], result);
  return result;
}

static Value bi_string_join(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2 || args[1].tag != T_STR) cvm_abort("string-join: expected (list sep)");
  FIOBJ buf = fiobj_str_buf(64);
  Value cur = args[0];
  int first = 1;
  while (cur.tag == T_PAIR) {
    if (cur.as.pair->car.tag != T_STR) cvm_abort("string-join: expected a list of strings");
    if (!first) fiobj_str_write(buf, args[1].as.str.chars, (size_t)args[1].as.str.len);
    first = 0;
    fiobj_str_write(buf, cur.as.pair->car.as.str.chars, (size_t)cur.as.pair->car.as.str.len);
    cur = cur.as.pair->cdr;
  }
  return fio_buf_to_value(buf);
}

static Value bi_string_replace(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 3 || args[0].tag != T_STR || args[1].tag != T_STR || args[2].tag != T_STR) {
    cvm_abort("string-replace: expected (string from to)");
  }
  const char *s = args[0].as.str.chars;
  int slen = args[0].as.str.len;
  const char *from = args[1].as.str.chars;
  int fromlen = args[1].as.str.len;
  FIOBJ buf = fiobj_str_buf((size_t)slen);
  if (fromlen == 0) {
    fiobj_str_write(buf, s, (size_t)slen);
    return fio_buf_to_value(buf);
  }
  int i = 0;
  while (i < slen) {
    if (i <= slen - fromlen && memcmp(s + i, from, (size_t)fromlen) == 0) {
      fiobj_str_write(buf, args[2].as.str.chars, (size_t)args[2].as.str.len);
      i += fromlen;
    } else {
      fiobj_str_write(buf, s + i, 1);
      i++;
    }
  }
  return fio_buf_to_value(buf);
}

static Value bi_string_translate(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2 || args[0].tag != T_STR) cvm_abort("string-translate: expected (string alist)");
  const char *s = args[0].as.str.chars;
  int slen = args[0].as.str.len;
  FIOBJ buf = fiobj_str_buf((size_t)slen);
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
      fiobj_str_write(buf, replacement.as.str.chars, (size_t)replacement.as.str.len);
    } else {
      fiobj_str_write(buf, &c, 1);
    }
  }
  return fio_buf_to_value(buf);
}

static Value bi_string_contains_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2 || args[0].tag != T_STR || args[1].tag != T_STR) cvm_abort("string-contains?: expected two strings");
  return v_bool(find_substring(args[0], args[1]) >= 0);
}

static Value bi_string_prefix_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2 || args[0].tag != T_STR || args[1].tag != T_STR) cvm_abort("string-prefix?: expected two strings");
  int hlen = args[0].as.str.len, nlen = args[1].as.str.len;
  return v_bool(hlen >= nlen && memcmp(args[0].as.str.chars, args[1].as.str.chars, (size_t)nlen) == 0);
}

static Value bi_string_suffix_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2 || args[0].tag != T_STR || args[1].tag != T_STR) cvm_abort("string-suffix?: expected two strings");
  int hlen = args[0].as.str.len, nlen = args[1].as.str.len;
  return v_bool(hlen >= nlen && memcmp(args[0].as.str.chars + (hlen - nlen), args[1].as.str.chars, (size_t)nlen) == 0);
}

static Value bi_string_index_of(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2 || args[0].tag != T_STR || args[1].tag != T_STR) cvm_abort("string-index-of: expected two strings");
  int idx = find_substring(args[0], args[1]);
  return idx >= 0 ? v_int(idx) : v_bool(0);
}

static Value bi_string_repeat(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2 || args[0].tag != T_STR || args[1].tag != T_INT) cvm_abort("string-repeat: expected (string n)");
  if (args[1].as.i < 0) cvm_abort("string-repeat: count must be non-negative");
  FIOBJ buf = fiobj_str_buf((size_t)args[0].as.str.len * (size_t)(args[1].as.i > 0 ? args[1].as.i : 1));
  for (int64_t i = 0; i < args[1].as.i; i++) fiobj_str_write(buf, args[0].as.str.chars, (size_t)args[0].as.str.len);
  return fio_buf_to_value(buf);
}

static Value bi_string_pad(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 3 || args[0].tag != T_STR || args[1].tag != T_INT || args[2].tag != T_STR) {
    cvm_abort("string-pad: expected (string len pad)");
  }
  if (args[2].as.str.len != 1) cvm_abort("string-pad: pad string must be exactly 1 char");
  int64_t target = args[1].as.i;
  int slen = args[0].as.str.len;
  if (slen >= target) return args[0];
  char padc = args[2].as.str.chars[0];
  FIOBJ buf = fiobj_str_buf((size_t)target);
  for (int64_t i = 0; i < target - slen; i++) fiobj_str_write(buf, &padc, 1);
  fiobj_str_write(buf, args[0].as.str.chars, (size_t)slen);
  return fio_buf_to_value(buf);
}

static Value bi_string_pad_right(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 3 || args[0].tag != T_STR || args[1].tag != T_INT || args[2].tag != T_STR) {
    cvm_abort("string-pad-right: expected (string len pad)");
  }
  if (args[2].as.str.len != 1) cvm_abort("string-pad-right: pad string must be exactly 1 char");
  int64_t target = args[1].as.i;
  int slen = args[0].as.str.len;
  if (slen >= target) return args[0];
  char padc = args[2].as.str.chars[0];
  FIOBJ buf = fiobj_str_buf((size_t)target);
  fiobj_str_write(buf, args[0].as.str.chars, (size_t)slen);
  for (int64_t i = 0; i < target - slen; i++) fiobj_str_write(buf, &padc, 1);
  return fio_buf_to_value(buf);
}

/* ---- format ---- */

static void format_write_display(FIOBJ buf, Value v) {
  switch (v.tag) {
  case T_STR:
  case T_SYM:
    fiobj_str_write(buf, v.as.str.chars, (size_t)v.as.str.len);
    break;
  case T_INT: {
    char tmp[32];
    int len = snprintf(tmp, sizeof(tmp), "%lld", (long long)v.as.i);
    fiobj_str_write(buf, tmp, (size_t)len);
    break;
  }
  case T_FLOAT: {
    char tmp[64];
    double f = v.as.f;
    int len = (fabs(f) < 1e15 && f == (double)(int64_t)f) ? snprintf(tmp, sizeof(tmp), "%lld.0", (long long)f)
                                                           : snprintf(tmp, sizeof(tmp), "%.17g", f);
    fiobj_str_write(buf, tmp, (size_t)len);
    break;
  }
  case T_BOOL:
    fiobj_str_write(buf, v.as.b ? "#t" : "#f", 2);
    break;
  case T_NIL:
    fiobj_str_write(buf, "()", 2);
    break;
  case T_CHAR: {
    char c = (char)v.as.i;
    fiobj_str_write(buf, &c, 1);
    break;
  }
  default:
    fiobj_str_write(buf, "#<object>", 9);
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
  if (nargs < 2) cvm_abort("format: expected (dest fmt . args)");
  if (args[0].tag != T_BOOL) cvm_abort("format: expected #t or #f as destination");
  if (args[1].tag != T_STR) cvm_abort("format: expected a format string");
  const char *fmt = args[1].as.str.chars;
  int fmtlen = args[1].as.str.len;
  FIOBJ buf = fiobj_str_buf((size_t)fmtlen);
  int argi = 2;
  int i = 0;
  while (i < fmtlen) {
    char c = fmt[i];
    if (c != '~') {
      fiobj_str_write(buf, &c, 1);
      i++;
      continue;
    }
    if (i + 1 >= fmtlen) cvm_abort("format: dangling '~' at end of format string");
    char directive = fmt[i + 1];
    char lower = (directive >= 'A' && directive <= 'Z') ? (char)(directive - 'A' + 'a') : directive;
    i += 2;
    switch (lower) {
    case '~':
      fiobj_str_write(buf, "~", 1);
      break;
    case '%':
      fiobj_str_write(buf, "\n", 1);
      break;
    case 'a':
    case 's':
      if (argi >= nargs) cvm_abort("format: not enough arguments for format string");
      format_write_display(buf, args[argi]);
      argi++;
      break;
    case 'c':
      if (argi >= nargs) cvm_abort("format: not enough arguments for format string");
      if (args[argi].tag != T_CHAR) cvm_abort("format: ~c expected a char");
      {
        char ch = (char)args[argi].as.i;
        fiobj_str_write(buf, &ch, 1);
      }
      argi++;
      break;
    case 'd':
    case 'x':
    case 'o':
    case 'b': {
      if (argi >= nargs) cvm_abort("format: not enough arguments for format string");
      if (args[argi].tag != T_INT) cvm_abort("format: expected an integer");
      int base = lower == 'd' ? 10 : lower == 'x' ? 16 : lower == 'o' ? 8 : 2;
      char numbuf[80];
      format_int_radix(args[argi].as.i, base, numbuf, sizeof(numbuf));
      fiobj_str_write(buf, numbuf, strlen(numbuf));
      argi++;
      break;
    }
    default:
      cvm_abort("format: unknown format directive '~%c'", directive);
    }
  }
  if (!args[0].as.b) {
    return fio_buf_to_value(buf);
  }
  fio_str_info_s info = fiobj_obj2cstr(buf);
  fwrite(info.data, 1, info.len, stdout);
  fiobj_free(buf);
  return v_nil();
}

void cvm_register_string_builtins(VM *vm) {
  cvm_register_builtin(vm, "string-upcase", bi_string_upcase);
  cvm_register_builtin(vm, "string-downcase", bi_string_downcase);
  /* (scheme char)'s string-foldcase is literally the same as string-downcase
   * (native's own comment: "correct for the ASCII/simple-Unicode range
   * this interpreter otherwise handles") -- same function, second name. */
  cvm_register_builtin(vm, "string-foldcase", bi_string_downcase);
  cvm_register_builtin(vm, "string-trim", bi_string_trim);
  cvm_register_builtin(vm, "string-reverse", bi_string_reverse);
  cvm_register_builtin(vm, "string-split", bi_string_split);
  cvm_register_builtin(vm, "string-join", bi_string_join);
  cvm_register_builtin(vm, "string-replace", bi_string_replace);
  cvm_register_builtin(vm, "string-translate", bi_string_translate);
  cvm_register_builtin(vm, "string-contains?", bi_string_contains_p);
  cvm_register_builtin(vm, "string-prefix?", bi_string_prefix_p);
  cvm_register_builtin(vm, "string-suffix?", bi_string_suffix_p);
  cvm_register_builtin(vm, "string-index-of", bi_string_index_of);
  cvm_register_builtin(vm, "string-repeat", bi_string_repeat);
  cvm_register_builtin(vm, "string-pad", bi_string_pad);
  cvm_register_builtin(vm, "string-pad-right", bi_string_pad_right);
  cvm_register_builtin(vm, "format", bi_format);
}
