/* (creme json) — see json.h. A port of src/creme/modules/creme/json.cr:
 * json-read/json-write. Crystal's own `require "json"` is standard
 * library, not an external shard (see shard.yml) -- this is a small
 * hand-rolled recursive-descent JSON parser/writer in C, since cvm has
 * no JSON support to reuse from anywhere else.
 *
 * Matches native's own conventions exactly: a JSON array decodes to a
 * T_VECTOR; a JSON object decodes to an alist of (T_STR key . value)
 * pairs (usable directly with assoc/cdr/set-cdr!/car, same as native),
 * built in source order; an empty object and JSON null both decode to
 * '() (a genuine tradeoff native accepts too -- an alist built from zero
 * pairs IS '(), not a special case). json-write mirrors this on the way
 * out: a proper list whose every element is itself a (string . value)
 * pair is written as a JSON object, any other proper list as a JSON
 * array (so plain Scheme lists round-trip too), an improper list or any
 * other unsupported value raises. */
#include <gc.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "json.h"

/* ---- growable output buffer (json-write) --------------------------------- */

typedef struct {
  char *buf;
  int len, cap;
} GBuf;

static void gbuf_init(GBuf *b) {
  b->cap = 64;
  b->buf = GC_MALLOC((size_t)b->cap);
  b->len = 0;
}

static void gbuf_reserve(GBuf *b, int extra) {
  if (b->len + extra <= b->cap) return;
  int newcap = b->cap * 2;
  while (newcap < b->len + extra) newcap *= 2;
  char *nb = GC_MALLOC((size_t)newcap);
  memcpy(nb, b->buf, (size_t)b->len);
  b->buf = nb;
  b->cap = newcap;
}

static void gbuf_putc(GBuf *b, char c) {
  gbuf_reserve(b, 1);
  b->buf[b->len++] = c;
}

static void gbuf_puts(GBuf *b, const char *s, int n) {
  gbuf_reserve(b, n);
  memcpy(b->buf + b->len, s, (size_t)n);
  b->len += n;
}

static void gbuf_printf(GBuf *b, const char *fmt, ...) {
  char tmp[64];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(tmp, sizeof(tmp), fmt, ap);
  va_end(ap);
  if (n < (int)sizeof(tmp)) {
    gbuf_puts(b, tmp, n);
    return;
  }
  char *big = GC_MALLOC((size_t)n + 1);
  va_start(ap, fmt);
  vsnprintf(big, (size_t)n + 1, fmt, ap);
  va_end(ap);
  gbuf_puts(b, big, n);
}

/* ---- growable Value array (json-read's object/array element lists) ------ */

typedef struct {
  Value *items;
  int len, cap;
} VArr;

static void varr_init(VArr *a) {
  a->cap = 8;
  a->items = GC_MALLOC(sizeof(Value) * (size_t)a->cap);
  a->len = 0;
}

static void varr_push(VArr *a, Value v) {
  if (a->len >= a->cap) {
    int newcap = a->cap * 2;
    Value *ni = GC_MALLOC(sizeof(Value) * (size_t)newcap);
    memcpy(ni, a->items, sizeof(Value) * (size_t)a->len);
    a->items = ni;
    a->cap = newcap;
  }
  a->items[a->len++] = v;
}

/* ---- reader --------------------------------------------------------------
 * Always runs on an actual actor's own VM thread (json-read is a plain
 * builtin call, never invoked from a bare network I/O thread the way
 * (creme actor)'s own wire decoder is) -- cvm_abort on a malformed
 * document is correct here. */

typedef struct {
  const char *s;
  int pos, len;
} JReader;

static void jr_skip_ws(JReader *r) {
  while (r->pos < r->len) {
    char c = r->s[r->pos];
    if (c != ' ' && c != '\t' && c != '\n' && c != '\r') break;
    r->pos++;
  }
}

static Value json_parse_value(JReader *r);

static Value json_parse_string(JReader *r) {
  r->pos++; /* opening quote */
  GBuf b;
  gbuf_init(&b);
  while (r->pos < r->len && r->s[r->pos] != '"') {
    unsigned char c = (unsigned char)r->s[r->pos++];
    if (c == '\\') {
      if (r->pos >= r->len) cvm_abort("json-read: invalid json: unterminated string escape");
      char e = r->s[r->pos++];
      switch (e) {
        case '"':
          gbuf_putc(&b, '"');
          break;
        case '\\':
          gbuf_putc(&b, '\\');
          break;
        case '/':
          gbuf_putc(&b, '/');
          break;
        case 'n':
          gbuf_putc(&b, '\n');
          break;
        case 't':
          gbuf_putc(&b, '\t');
          break;
        case 'r':
          gbuf_putc(&b, '\r');
          break;
        case 'b':
          gbuf_putc(&b, '\b');
          break;
        case 'f':
          gbuf_putc(&b, '\f');
          break;
        case 'u': {
          if (r->pos + 4 > r->len) cvm_abort("json-read: invalid json: truncated \\u escape");
          char hex[5];
          memcpy(hex, r->s + r->pos, 4);
          hex[4] = '\0';
          r->pos += 4;
          long cp = strtol(hex, NULL, 16);
          /* Encodes as UTF-8 bytes -- cvm's own strings are raw bytes with
           * no real UTF-8 decoding elsewhere either, so this just needs to
           * round-trip, not decode further. No surrogate-pair handling
           * (an astral codepoint split across two \uXXXX escapes) -- a
           * narrower, deliberate cut matching this file's own small scope. */
          if (cp < 0x80) {
            gbuf_putc(&b, (char)cp);
          } else if (cp < 0x800) {
            gbuf_putc(&b, (char)(0xC0 | (cp >> 6)));
            gbuf_putc(&b, (char)(0x80 | (cp & 0x3f)));
          } else {
            gbuf_putc(&b, (char)(0xE0 | (cp >> 12)));
            gbuf_putc(&b, (char)(0x80 | ((cp >> 6) & 0x3f)));
            gbuf_putc(&b, (char)(0x80 | (cp & 0x3f)));
          }
          break;
        }
        default:
          cvm_abort("json-read: invalid json: invalid escape character '\\%c'", e);
      }
    } else {
      gbuf_putc(&b, (char)c);
    }
  }
  if (r->pos >= r->len) cvm_abort("json-read: invalid json: unterminated string");
  r->pos++; /* closing quote */
  return v_str(b.buf, b.len);
}

static Value json_parse_number(JReader *r) {
  int start = r->pos;
  if (r->pos < r->len && r->s[r->pos] == '-') r->pos++;
  while (r->pos < r->len && r->s[r->pos] >= '0' && r->s[r->pos] <= '9') r->pos++;
  int is_float = 0;
  if (r->pos < r->len && r->s[r->pos] == '.') {
    is_float = 1;
    r->pos++;
    while (r->pos < r->len && r->s[r->pos] >= '0' && r->s[r->pos] <= '9') r->pos++;
  }
  if (r->pos < r->len && (r->s[r->pos] == 'e' || r->s[r->pos] == 'E')) {
    is_float = 1;
    r->pos++;
    if (r->pos < r->len && (r->s[r->pos] == '+' || r->s[r->pos] == '-')) r->pos++;
    while (r->pos < r->len && r->s[r->pos] >= '0' && r->s[r->pos] <= '9') r->pos++;
  }
  int tok_len = r->pos - start;
  if (tok_len == 0 || (tok_len == 1 && r->s[start] == '-')) cvm_abort("json-read: invalid json: malformed number");
  char tmp[64];
  int n = tok_len < (int)sizeof(tmp) - 1 ? tok_len : (int)sizeof(tmp) - 1;
  memcpy(tmp, r->s + start, (size_t)n);
  tmp[n] = '\0';
  if (is_float) return v_float(strtod(tmp, NULL));
  return v_int(strtoll(tmp, NULL, 10));
}

static Value json_parse_object(JReader *r) {
  r->pos++; /* '{' */
  jr_skip_ws(r);
  if (r->pos < r->len && r->s[r->pos] == '}') {
    r->pos++;
    return v_nil(); /* an empty object conflates with null -- see this file's own header comment */
  }
  VArr entries;
  varr_init(&entries);
  for (;;) {
    jr_skip_ws(r);
    if (r->pos >= r->len || r->s[r->pos] != '"') cvm_abort("json-read: invalid json: expected a string key");
    Value key = json_parse_string(r);
    jr_skip_ws(r);
    if (r->pos >= r->len || r->s[r->pos] != ':') cvm_abort("json-read: invalid json: expected ':' after object key");
    r->pos++;
    jr_skip_ws(r);
    Value val = json_parse_value(r);
    Pair *p = GC_MALLOC(sizeof(Pair));
    p->car = key;
    p->cdr = val;
    varr_push(&entries, v_pair(p));
    jr_skip_ws(r);
    if (r->pos < r->len && r->s[r->pos] == ',') {
      r->pos++;
      continue;
    }
    if (r->pos < r->len && r->s[r->pos] == '}') {
      r->pos++;
      break;
    }
    cvm_abort("json-read: invalid json: expected ',' or '}' in object");
  }
  Value result = v_nil();
  for (int i = entries.len - 1; i >= 0; i--) {
    Pair *p = GC_MALLOC(sizeof(Pair));
    p->car = entries.items[i];
    p->cdr = result;
    result = v_pair(p);
  }
  return result;
}

static Value json_parse_array(JReader *r) {
  r->pos++; /* '[' */
  VArr items;
  varr_init(&items);
  jr_skip_ws(r);
  if (r->pos < r->len && r->s[r->pos] == ']') {
    r->pos++;
  } else {
    for (;;) {
      jr_skip_ws(r);
      Value v = json_parse_value(r);
      varr_push(&items, v);
      jr_skip_ws(r);
      if (r->pos < r->len && r->s[r->pos] == ',') {
        r->pos++;
        continue;
      }
      if (r->pos < r->len && r->s[r->pos] == ']') {
        r->pos++;
        break;
      }
      cvm_abort("json-read: invalid json: expected ',' or ']' in array");
    }
  }
  Vector *vec = GC_MALLOC(sizeof(Vector));
  vec->items = GC_MALLOC(sizeof(Value) * (size_t)(items.len > 0 ? items.len : 1));
  memcpy(vec->items, items.items, sizeof(Value) * (size_t)items.len);
  vec->len = items.len;
  return v_vector(vec);
}

static Value json_parse_value(JReader *r) {
  jr_skip_ws(r);
  if (r->pos >= r->len) cvm_abort("json-read: invalid json: unexpected end of input");
  char c = r->s[r->pos];
  if (c == '{') return json_parse_object(r);
  if (c == '[') return json_parse_array(r);
  if (c == '"') return json_parse_string(r);
  if (c == 't') {
    if (r->pos + 4 > r->len || memcmp(r->s + r->pos, "true", 4) != 0) cvm_abort("json-read: invalid json: malformed literal");
    r->pos += 4;
    return v_bool(1);
  }
  if (c == 'f') {
    if (r->pos + 5 > r->len || memcmp(r->s + r->pos, "false", 5) != 0) cvm_abort("json-read: invalid json: malformed literal");
    r->pos += 5;
    return v_bool(0);
  }
  if (c == 'n') {
    if (r->pos + 4 > r->len || memcmp(r->s + r->pos, "null", 4) != 0) cvm_abort("json-read: invalid json: malformed literal");
    r->pos += 4;
    return v_nil();
  }
  if (c == '-' || (c >= '0' && c <= '9')) return json_parse_number(r);
  cvm_abort("json-read: invalid json: unexpected character '%c'", c);
}

static Value bi_json_read(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) cvm_abort("json-read: expected string, got a non-string value");
  JReader r;
  r.s = args[0].as.chars;
  r.pos = 0;
  r.len = args[0].aux;
  Value result = json_parse_value(&r);
  jr_skip_ws(&r);
  if (r.pos != r.len) cvm_abort("json-read: invalid json: unexpected trailing content");
  return result;
}

/* ---- writer --------------------------------------------------------------- */

static int is_proper_list(Value v) {
  while (v.tag == T_PAIR) v = v.as.pair->cdr;
  return v.tag == T_NIL;
}

/* Matches native's own json_alist? exactly: a NON-EMPTY proper list whose
 * every element is a Cons with a T_STR car. */
static int is_json_alist(Value v) {
  if (v.tag != T_PAIR || !is_proper_list(v)) return 0;
  for (Value cur = v; cur.tag == T_PAIR; cur = cur.as.pair->cdr) {
    Value elem = cur.as.pair->car;
    if (elem.tag != T_PAIR || elem.as.pair->car.tag != T_STR) return 0;
  }
  return 1;
}

static void json_write_string(GBuf *w, const char *s, int len) {
  gbuf_putc(w, '"');
  for (int i = 0; i < len; i++) {
    unsigned char c = (unsigned char)s[i];
    switch (c) {
      case '"':
        gbuf_puts(w, "\\\"", 2);
        break;
      case '\\':
        gbuf_puts(w, "\\\\", 2);
        break;
      case '\n':
        gbuf_puts(w, "\\n", 2);
        break;
      case '\r':
        gbuf_puts(w, "\\r", 2);
        break;
      case '\t':
        gbuf_puts(w, "\\t", 2);
        break;
      default:
        if (c < 0x20) {
          gbuf_printf(w, "\\u%04x", c);
        } else {
          gbuf_putc(w, (char)c);
        }
    }
  }
  gbuf_putc(w, '"');
}

static void json_write_value(GBuf *w, Value v, const char *who) {
  switch (v.tag) {
    case T_NIL:
      gbuf_puts(w, "null", 4);
      return;
    case T_BOOL:
      gbuf_puts(w, v.as.b ? "true" : "false", v.as.b ? 4 : 5);
      return;
    case T_INT:
      gbuf_printf(w, "%lld", (long long)v.as.i);
      return;
    case T_FLOAT: {
      char tmp[64];
      int n = snprintf(tmp, sizeof(tmp), "%.17g", v.as.f);
      gbuf_puts(w, tmp, n);
      if (!strchr(tmp, '.') && !strchr(tmp, 'e') && !strchr(tmp, 'n')) gbuf_puts(w, ".0", 2);
      return;
    }
    case T_STR:
      json_write_string(w, v.as.chars, v.aux);
      return;
    case T_CHAR: {
      char c = (char)v.as.i;
      json_write_string(w, &c, 1);
      return;
    }
    case T_VECTOR: {
      gbuf_putc(w, '[');
      for (int i = 0; i < v.as.vec->len; i++) {
        if (i) gbuf_putc(w, ',');
        json_write_value(w, v.as.vec->items[i], who);
      }
      gbuf_putc(w, ']');
      return;
    }
    case T_PAIR:
      if (is_json_alist(v)) {
        gbuf_putc(w, '{');
        int first = 1;
        for (Value cur = v; cur.tag == T_PAIR; cur = cur.as.pair->cdr) {
          Value entry = cur.as.pair->car;
          if (!first) gbuf_putc(w, ',');
          first = 0;
          json_write_string(w, entry.as.pair->car.as.chars, entry.as.pair->car.aux);
          gbuf_putc(w, ':');
          json_write_value(w, entry.as.pair->cdr, who);
        }
        gbuf_putc(w, '}');
      } else {
        if (!is_proper_list(v)) cvm_abort("%s: cannot serialize improper list", who);
        gbuf_putc(w, '[');
        int first = 1;
        for (Value cur = v; cur.tag == T_PAIR; cur = cur.as.pair->cdr) {
          if (!first) gbuf_putc(w, ',');
          first = 0;
          json_write_value(w, cur.as.pair->car, who);
        }
        gbuf_putc(w, ']');
      }
      return;
    default:
      cvm_abort("%s: cannot serialize this value", who);
  }
}

static Value bi_json_write(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("json-write: expected an argument");
  GBuf b;
  gbuf_init(&b);
  json_write_value(&b, args[0], "json-write");
  return v_str(b.buf, b.len);
}

void cvm_register_json_builtins(VM *vm) {
  cvm_register_builtin(vm, "json-read", bi_json_read);
  cvm_register_builtin(vm, "json-write", bi_json_write);
}
