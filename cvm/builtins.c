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
  case T_CLOSURE:
    fputs("#<procedure>", out);
    break;
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
static Value bi_boolean_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("boolean?: expected an argument"); return v_bool(args[0].tag == T_BOOL); }
static Value bi_symbol_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("symbol?: expected an argument"); return v_bool(args[0].tag == T_SYM); }
static Value bi_string_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("string?: expected an argument"); return v_bool(args[0].tag == T_STR); }
static Value bi_vector_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("vector?: expected an argument"); return v_bool(args[0].tag == T_VECTOR); }
static Value bi_char_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("char?: expected an argument"); return v_bool(args[0].tag == T_CHAR); }
static Value bi_procedure_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("procedure?: expected an argument"); return v_bool(args[0].tag == T_CLOSURE || args[0].tag == T_BUILTIN); }
static Value bi_number_p(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1) cvm_abort("number?: expected an argument"); return v_bool(args[0].tag == T_INT || args[0].tag == T_FLOAT); }
static Value bi_real_p(VM *vm, Value *args, int nargs) { return bi_number_p(vm, args, nargs); } /* no complex tower */
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
static Value bi_values(VM *vm, Value *args, int nargs) { (void)vm; return nargs >= 1 ? args[0] : v_nil(); }
static Value bi_call_with_values(VM *vm, Value *args, int nargs) {
  if (nargs < 2) cvm_abort("call-with-values: expected (producer consumer)");
  Value produced = cvm_apply(vm, args[0], NULL, 0);
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
static Value bi_substring(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2 || args[0].tag != T_STR || args[1].tag != T_INT) cvm_abort("substring: expected (string start [end])");
  int start = (int)args[1].as.i;
  int end = (nargs >= 3 && args[2].tag == T_INT) ? (int)args[2].as.i : args[0].as.str.len;
  if (start < 0 || end > args[0].as.str.len || start > end) cvm_abort("substring: index out of range");
  return v_str(args[0].as.str.chars + start, end - start);
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
static Value bi_string_to_symbol(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1 || args[0].tag != T_STR) cvm_abort("string->symbol: expected a string"); return v_sym(args[0].as.str.chars, args[0].as.str.len); }
static Value bi_symbol_to_string(VM *vm, Value *args, int nargs) { (void)vm; if (nargs < 1 || args[0].tag != T_SYM) cvm_abort("symbol->string: expected a symbol"); return v_str(args[0].as.str.chars, args[0].as.str.len); }
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
static Value bi_error(VM *vm, Value *args, int nargs) {
  (void)vm;
  fprintf(stderr, "error: ");
  for (int i = 0; i < nargs; i++) {
    if (i) fputc(' ', stderr);
    print_value(stderr, args[i]);
  }
  fputc('\n', stderr);
  exit(1);
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
  cvm_register_builtin(vm, "boolean?", bi_boolean_p);
  cvm_register_builtin(vm, "symbol?", bi_symbol_p);
  cvm_register_builtin(vm, "string?", bi_string_p);
  cvm_register_builtin(vm, "vector?", bi_vector_p);
  cvm_register_builtin(vm, "char?", bi_char_p);
  cvm_register_builtin(vm, "procedure?", bi_procedure_p);
  cvm_register_builtin(vm, "number?", bi_number_p);
  cvm_register_builtin(vm, "real?", bi_real_p);
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
  cvm_register_builtin(vm, "filter", bi_filter);
  cvm_register_builtin(vm, "values", bi_values);
  cvm_register_builtin(vm, "call-with-values", bi_call_with_values);

  cvm_register_builtin(vm, "string-append", bi_string_append);
  cvm_register_builtin(vm, "substring", bi_substring);
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

  cvm_register_builtin(vm, "vector", bi_vector);
  cvm_register_builtin(vm, "vector->list", bi_vector_to_list);
  cvm_register_builtin(vm, "list->vector", bi_list_to_vector);

  cvm_register_builtin(vm, "error", bi_error);
  cvm_register_builtin(vm, "read-line", bi_read_line);
  cvm_register_builtin(vm, "current-time", bi_current_time);
  cvm_register_builtin(vm, "time-difference", bi_time_difference);
  cvm_register_builtin(vm, "get-environment-variable", bi_get_environment_variable);
}
