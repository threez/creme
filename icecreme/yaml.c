/* (creme yaml) — see yaml.h. Unlike json.c (hand-rolled, since icecreme had no
 * JSON support to reuse from anywhere), this wraps libyaml directly --
 * writing a YAML 1.1 parser/emitter from scratch would be a much bigger
 * lift than JSON's recursive descent, and native's own (creme yaml)
 * (src/creme/modules/creme/yaml.cr) already leans on Crystal's stdlib
 * `YAML`, itself a libyaml wrapper -- so both backends end up backed by
 * the same underlying C library either way.
 *
 * Matches native's own conventions exactly: a YAML sequence decodes to a
 * T_VECTOR; a YAML mapping decodes to an alist of (T_STR key . value)
 * pairs (usable directly with assoc/cdr/set-cdr!/car, same as native),
 * built in source order; an empty mapping and YAML null both decode to
 * '() (the same tradeoff (creme json) makes). yaml-write mirrors this on
 * the way out: a proper list whose every element is itself a
 * (string . value) pair is written as a mapping, any other proper list as
 * a sequence, an improper list or any other unsupported value raises.
 * Only a single document is read/written -- a multi-document stream is
 * out of scope, matching (creme xml)/(creme matrix)'s own narrower scopes.
 *
 * Mapping KEYS are always taken as their literal scalar text (e.g. a key
 * spelled "0x1F" stays the string "0x1F"), never run through the
 * value-side type resolution below -- this is a deliberate, narrow
 * divergence from native, where a key goes through the same typed
 * YAML::Any resolution a value does and is then stringified via `to_s`
 * (so a key spelled "on" becomes the string "true" on the Crystal side,
 * since YAML's bool-word resolution already turned it into an actual
 * `true` before `to_s` ever saw it) -- native's behavior is arguably more
 * surprising for a mapping key, and no real YAML document uses a
 * bool-word or non-decimal-formatted numeric key, so this divergence is
 * accepted rather than reproduced.
 *
 * Scalar type resolution (null/bool/int/float vs plain string) follows
 * the YAML 1.1 "core schema" words libyaml itself recognizes as
 * conventional (used here since that's what both PyYAML/Psych/Crystal's
 * own YAML.parse resolve too) -- and ONLY applies to a plain (unquoted)
 * scalar; anything single/double-quoted or block (|/>) stays a string
 * unconditionally, matching every other YAML implementation's own rule
 * that quoting is an explicit "this is definitely a string" signal. */
#include <ctype.h>
#include <gc.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <yaml.h>

#include "yaml.h"

/* ---- growable output buffer (yaml-write) --------------------------------- */

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

static void gbuf_puts(GBuf *b, const char *s, int n) {
  gbuf_reserve(b, n);
  memcpy(b->buf + b->len, s, (size_t)n);
  b->len += n;
}

/* ---- growable Value array (yaml-read's sequence/mapping element lists) --- */

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

/* GC-owned copy -- unlike json.c's v_str (which can point straight into
 * its own GBuf), a libyaml event's scalar.value buffer is only valid
 * until yaml_event_delete, so every scalar must be copied out before that. */
static Value v_str_copy(const char *s, int len) {
  char *buf = GC_MALLOC((size_t)len + 1);
  memcpy(buf, s, (size_t)len);
  buf[len] = '\0';
  return v_str(buf, len);
}

/* ---- reader --------------------------------------------------------------- */

static void yaml_next_event(yaml_parser_t *parser, yaml_event_t *event) {
  if (!yaml_parser_parse(parser, event))
    cvm_abort("yaml-read: invalid yaml: %s", parser->problem ? parser->problem : "parse error");
}

static int yaml_text_is(const char *s, int len, const char *lit) {
  size_t litlen = strlen(lit);
  return (size_t)len == litlen && memcmp(s, lit, litlen) == 0;
}

static int yaml_strip_underscores(const char *s, int len, char *out) {
  int j = 0;
  for (int i = 0; i < len; i++)
    if (s[i] != '_') out[j++] = s[i];
  out[j] = '\0';
  return j;
}

static int yaml_try_parse_int(const char *s, int len, Value *out) {
  char buf[128];
  if (len <= 0 || len >= (int)sizeof(buf)) return 0;
  int blen = yaml_strip_underscores(s, len, buf);
  if (blen == 0) return 0;
  int idx = 0, neg = 0;
  if (buf[idx] == '+') {
    idx++;
  } else if (buf[idx] == '-') {
    neg = 1;
    idx++;
  }
  if (idx >= blen) return 0;
  int base = 10, digits_start = idx;
  if (blen - idx > 2 && buf[idx] == '0' && (buf[idx + 1] == 'x' || buf[idx + 1] == 'X')) {
    base = 16;
    digits_start = idx + 2;
  } else if (blen - idx > 2 && buf[idx] == '0' && (buf[idx + 1] == 'o' || buf[idx + 1] == 'O')) {
    base = 8;
    digits_start = idx + 2;
  } else if (blen - idx > 1 && buf[idx] == '0' && buf[idx + 1] >= '0' && buf[idx + 1] <= '9') {
    base = 8; /* legacy leading-zero octal, e.g. "010" -- matches Crystal's own YAML.parse */
    digits_start = idx + 1;
  }
  if (digits_start >= blen) return 0;
  for (int i = digits_start; i < blen; i++) {
    unsigned char c = (unsigned char)buf[i];
    int okay = base == 16 ? isxdigit(c) : base == 8 ? (c >= '0' && c <= '7') : isdigit(c);
    if (!okay) return 0;
  }
  char *endptr;
  long long val = strtoll(buf + digits_start, &endptr, base);
  if (*endptr != '\0') return 0;
  *out = v_int(neg ? -val : val);
  return 1;
}

static int yaml_try_parse_float(const char *s, int len, Value *out) {
  char buf[128];
  if (len <= 0 || len >= (int)sizeof(buf)) return 0;
  int blen = yaml_strip_underscores(s, len, buf);
  if (yaml_text_is(buf, blen, ".inf") || yaml_text_is(buf, blen, ".Inf") || yaml_text_is(buf, blen, ".INF") ||
      yaml_text_is(buf, blen, "+.inf") || yaml_text_is(buf, blen, "+.Inf") || yaml_text_is(buf, blen, "+.INF")) {
    *out = v_float(INFINITY);
    return 1;
  }
  if (yaml_text_is(buf, blen, "-.inf") || yaml_text_is(buf, blen, "-.Inf") || yaml_text_is(buf, blen, "-.INF")) {
    *out = v_float(-INFINITY);
    return 1;
  }
  if (yaml_text_is(buf, blen, ".nan") || yaml_text_is(buf, blen, ".NaN") || yaml_text_is(buf, blen, ".NAN")) {
    *out = v_float(NAN);
    return 1;
  }
  int has_dot_or_exp = 0;
  for (int i = 0; i < blen; i++)
    if (buf[i] == '.' || buf[i] == 'e' || buf[i] == 'E') {
      has_dot_or_exp = 1;
      break;
    }
  if (!has_dot_or_exp) return 0;
  char *endptr;
  double val = strtod(buf, &endptr);
  if (endptr != buf + blen) return 0;
  *out = v_float(val);
  return 1;
}

static Value yaml_resolve_scalar(yaml_event_t *event) {
  const char *s = (const char *)event->data.scalar.value;
  int len = (int)event->data.scalar.length;
  if (event->data.scalar.style != YAML_PLAIN_SCALAR_STYLE) return v_str_copy(s, len);

  if (len == 0 || yaml_text_is(s, len, "~") || yaml_text_is(s, len, "null") || yaml_text_is(s, len, "Null") ||
      yaml_text_is(s, len, "NULL"))
    return v_nil();

  static const char *true_words[] = {"true", "True", "TRUE", "yes", "Yes", "YES", "on", "On", "ON", NULL};
  static const char *false_words[] = {"false", "False", "FALSE", "no", "No", "NO", "off", "Off", "OFF", NULL};
  for (int i = 0; true_words[i]; i++)
    if (yaml_text_is(s, len, true_words[i])) return v_bool(1);
  for (int i = 0; false_words[i]; i++)
    if (yaml_text_is(s, len, false_words[i])) return v_bool(0);

  Value iv;
  if (yaml_try_parse_int(s, len, &iv)) return iv;
  Value fv;
  if (yaml_try_parse_float(s, len, &fv)) return fv;
  return v_str_copy(s, len);
}

static Value yaml_parse_value(yaml_parser_t *parser, yaml_event_t *event);

static Value yaml_parse_sequence(yaml_parser_t *parser) {
  VArr items;
  varr_init(&items);
  for (;;) {
    yaml_event_t ev;
    yaml_next_event(parser, &ev);
    if (ev.type == YAML_SEQUENCE_END_EVENT) {
      yaml_event_delete(&ev);
      break;
    }
    Value v = yaml_parse_value(parser, &ev);
    yaml_event_delete(&ev);
    varr_push(&items, v);
  }
  Vector *vec = GC_MALLOC(sizeof(Vector));
  vec->items = GC_MALLOC(sizeof(Value) * (size_t)(items.len > 0 ? items.len : 1));
  memcpy(vec->items, items.items, sizeof(Value) * (size_t)items.len);
  vec->len = items.len;
  return v_vector(vec);
}

static Value yaml_parse_mapping(yaml_parser_t *parser) {
  VArr entries;
  varr_init(&entries);
  for (;;) {
    yaml_event_t kev;
    yaml_next_event(parser, &kev);
    if (kev.type == YAML_MAPPING_END_EVENT) {
      yaml_event_delete(&kev);
      break;
    }
    if (kev.type != YAML_SCALAR_EVENT) cvm_abort("yaml-read: invalid yaml: only scalar mapping keys are supported");
    Value key = v_str_copy((const char *)kev.data.scalar.value, (int)kev.data.scalar.length);
    yaml_event_delete(&kev);

    yaml_event_t vev;
    yaml_next_event(parser, &vev);
    Value val = yaml_parse_value(parser, &vev);
    yaml_event_delete(&vev);

    Pair *p = GC_MALLOC(sizeof(Pair));
    p->car = key;
    p->cdr = val;
    varr_push(&entries, v_pair(p));
  }
  if (entries.len == 0) return v_nil(); /* an empty mapping conflates with null -- see this file's own header comment */
  Value result = v_nil();
  for (int i = entries.len - 1; i >= 0; i--) {
    Pair *p = GC_MALLOC(sizeof(Pair));
    p->car = entries.items[i];
    p->cdr = result;
    result = v_pair(p);
  }
  return result;
}

static Value yaml_parse_value(yaml_parser_t *parser, yaml_event_t *event) {
  switch (event->type) {
    case YAML_SCALAR_EVENT:
      return yaml_resolve_scalar(event);
    case YAML_SEQUENCE_START_EVENT:
      return yaml_parse_sequence(parser);
    case YAML_MAPPING_START_EVENT:
      return yaml_parse_mapping(parser);
    case YAML_ALIAS_EVENT:
      cvm_abort("yaml-read: anchors/aliases are not supported");
    default:
      cvm_abort("yaml-read: invalid yaml: unexpected event");
  }
}

static Value bi_yaml_read(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) cvm_abort("yaml-read: expected string, got a non-string value");

  yaml_parser_t parser;
  if (!yaml_parser_initialize(&parser)) cvm_abort("yaml-read: failed to initialize yaml parser");
  yaml_parser_set_input_string(&parser, (const unsigned char *)args[0].as.chars, (size_t)args[0].aux);

  yaml_event_t event;
  for (;;) {
    yaml_next_event(&parser, &event);
    if (event.type == YAML_STREAM_START_EVENT || event.type == YAML_DOCUMENT_START_EVENT) {
      yaml_event_delete(&event);
      continue;
    }
    break;
  }
  Value result = yaml_parse_value(&parser, &event);
  yaml_event_delete(&event);
  yaml_parser_delete(&parser);
  return result;
}

/* ---- writer ----------------------------------------------------------------
 * Mirrors native's own yaml_alist?/yaml_write dispatch (see yaml.cr) --
 * emitted via libyaml's own emitter rather than hand-formatted text, same
 * as the reader leans on libyaml's parser rather than a hand-rolled one. */

static int is_proper_list(Value v) {
  while (v.tag == T_PAIR) v = v.as.pair->cdr;
  return v.tag == T_NIL;
}

static int is_yaml_alist(Value v) {
  if (v.tag != T_PAIR || !is_proper_list(v)) return 0;
  for (Value cur = v; cur.tag == T_PAIR; cur = cur.as.pair->cdr) {
    Value elem = cur.as.pair->car;
    if (elem.tag != T_PAIR || elem.as.pair->car.tag != T_STR) return 0;
  }
  return 1;
}

static void yaml_emit_or_abort(yaml_emitter_t *emitter, yaml_event_t *event) {
  if (!yaml_emitter_emit(emitter, event)) cvm_abort("yaml-write: failed to emit yaml event");
}

static void yaml_emit_scalar(yaml_emitter_t *emitter, const char *s, int len) {
  yaml_event_t event;
  yaml_scalar_event_initialize(&event, NULL, NULL, (yaml_char_t *)s, len, 1, 1, YAML_ANY_SCALAR_STYLE);
  yaml_emit_or_abort(emitter, &event);
}

static void yaml_emit_value(yaml_emitter_t *emitter, Value v, const char *who) {
  switch (v.tag) {
    case T_NIL:
      yaml_emit_scalar(emitter, "", 0);
      return;
    case T_BOOL:
      yaml_emit_scalar(emitter, v.as.b ? "true" : "false", v.as.b ? 4 : 5);
      return;
    case T_INT: {
      char tmp[32];
      int n = snprintf(tmp, sizeof(tmp), "%lld", (long long)v.as.i);
      yaml_emit_scalar(emitter, tmp, n);
      return;
    }
    case T_FLOAT: {
      char tmp[64];
      int n;
      if (isinf(v.as.f)) {
        n = snprintf(tmp, sizeof(tmp), "%s", v.as.f < 0 ? "-.inf" : ".inf");
      } else if (isnan(v.as.f)) {
        n = snprintf(tmp, sizeof(tmp), ".nan");
      } else {
        n = snprintf(tmp, sizeof(tmp), "%.17g", v.as.f);
        if (!strchr(tmp, '.') && !strchr(tmp, 'e') && !strchr(tmp, 'n')) n += snprintf(tmp + n, sizeof(tmp) - (size_t)n, ".0");
      }
      yaml_emit_scalar(emitter, tmp, n);
      return;
    }
    case T_STR:
      yaml_emit_scalar(emitter, v.as.chars, v.aux);
      return;
    case T_CHAR: {
      char c = (char)v.as.i;
      yaml_emit_scalar(emitter, &c, 1);
      return;
    }
    case T_VECTOR: {
      yaml_event_t start, end;
      yaml_sequence_start_event_initialize(&start, NULL, NULL, 1, YAML_BLOCK_SEQUENCE_STYLE);
      yaml_emit_or_abort(emitter, &start);
      for (int i = 0; i < v.as.vec->len; i++) yaml_emit_value(emitter, v.as.vec->items[i], who);
      yaml_sequence_end_event_initialize(&end);
      yaml_emit_or_abort(emitter, &end);
      return;
    }
    case T_PAIR:
      if (is_yaml_alist(v)) {
        yaml_event_t start, end;
        yaml_mapping_start_event_initialize(&start, NULL, NULL, 1, YAML_BLOCK_MAPPING_STYLE);
        yaml_emit_or_abort(emitter, &start);
        for (Value cur = v; cur.tag == T_PAIR; cur = cur.as.pair->cdr) {
          Value entry = cur.as.pair->car;
          yaml_emit_scalar(emitter, entry.as.pair->car.as.chars, entry.as.pair->car.aux);
          yaml_emit_value(emitter, entry.as.pair->cdr, who);
        }
        yaml_mapping_end_event_initialize(&end);
        yaml_emit_or_abort(emitter, &end);
      } else {
        if (!is_proper_list(v)) cvm_abort("%s: cannot serialize improper list", who);
        yaml_event_t start, end;
        yaml_sequence_start_event_initialize(&start, NULL, NULL, 1, YAML_BLOCK_SEQUENCE_STYLE);
        yaml_emit_or_abort(emitter, &start);
        for (Value cur = v; cur.tag == T_PAIR; cur = cur.as.pair->cdr) yaml_emit_value(emitter, cur.as.pair->car, who);
        yaml_sequence_end_event_initialize(&end);
        yaml_emit_or_abort(emitter, &end);
      }
      return;
    default:
      cvm_abort("%s: cannot serialize this value", who);
  }
}

static int yaml_write_handler(void *data, unsigned char *buffer, size_t size) {
  gbuf_puts((GBuf *)data, (const char *)buffer, (int)size);
  return 1;
}

static Value bi_yaml_write(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("yaml-write: expected an argument");

  GBuf out;
  gbuf_init(&out);

  yaml_emitter_t emitter;
  if (!yaml_emitter_initialize(&emitter)) cvm_abort("yaml-write: failed to initialize yaml emitter");
  yaml_emitter_set_output(&emitter, yaml_write_handler, &out);

  yaml_event_t event;
  yaml_stream_start_event_initialize(&event, YAML_UTF8_ENCODING);
  yaml_emit_or_abort(&emitter, &event);
  /* implicit=0: always emit the leading "---" marker, matching native's own
   * YAML::Builder (which always writes it too, regardless of whether the
   * document would parse fine without it). */
  yaml_document_start_event_initialize(&event, NULL, NULL, NULL, 0);
  yaml_emit_or_abort(&emitter, &event);

  yaml_emit_value(&emitter, args[0], "yaml-write");

  yaml_document_end_event_initialize(&event, 1);
  yaml_emit_or_abort(&emitter, &event);
  yaml_stream_end_event_initialize(&event);
  yaml_emit_or_abort(&emitter, &event);
  yaml_emitter_flush(&emitter);
  yaml_emitter_delete(&emitter);

  return v_str(out.buf, out.len);
}

void cvm_register_yaml_builtins(VM *vm) {
  cvm_register_builtin(vm, "yaml-read", bi_yaml_read);
  cvm_register_builtin(vm, "yaml-write", bi_yaml_write);
}
