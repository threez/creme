/* (creme regex) — see regex.h.
 *
 * Originally only `regexp`/`regexp-matches?`, added so the self-hosted
 * reader (modules/creme/compiler/reader.sld) could run under icecreme at all
 * (it uses those two to classify numeric tokens -- int/rational/float/
 * complex). Backed by PCRE2 (the same regex flavor the real Crystal
 * `Regex` class itself uses), specifically so reader.sld's own patterns
 * -- written with PCRE-style `\A`/`\z` string anchors -- work completely
 * unchanged under icecreme; a POSIX <regex.h> backend would have needed those
 * patterns rewritten (POSIX ERE has no `\A`/`\z`), which risked the
 * shared reader.sld file behaving subtly differently under the two
 * backends. The rest of native's (creme regex) surface (regexp-search/
 * -extract/-replace[-all]/-split/regexp?) is now ported too, all built
 * on the shared regex_match_once helper below -- regexp-replace/
 * regexp-replace-all substitute their replacement string LITERALLY, not
 * expanding $1/$~[...]-style backreferences the way native's own
 * Crystal String#sub/#gsub does (see that helper's own comment) -- a
 * narrower, deliberate cut, same spirit as this file's original scope. */
#define PCRE2_CODE_UNIT_WIDTH 8
#include <pcre2.h>

#include <gc.h>
#include <string.h>

#include "embed.h"
#include "regex.h"

static Value bi_regexp(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 1 || args[0].tag != T_STR) creme_abort("regexp: expected a pattern string");
  int errcode;
  PCRE2_SIZE erroffset;
  pcre2_code *re = pcre2_compile((PCRE2_SPTR)args[0].as.chars, (PCRE2_SIZE)args[0].aux, 0, &errcode, &erroffset, NULL);
  if (!re) {
    PCRE2_UCHAR errbuf[256];
    pcre2_get_error_message(errcode, errbuf, sizeof(errbuf));
    creme_abort("regexp: invalid pattern: %s", (char *)errbuf);
  }
  return v_box(re, BOX_KIND_REGEX);
}

static Value bi_regexp_matches_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 2 || args[0].tag != T_BOX || args[0].aux != BOX_KIND_REGEX || args[1].tag != T_STR) {
    creme_abort("regexp-matches?: expected (regexp string)");
  }
  pcre2_code *re = (pcre2_code *)args[0].as.ptr;
  /* Short-lived scratch space, freed immediately after use -- unlike the
   * compiled pattern itself (`re`, GC-owned via v_box, intentionally kept
   * alive for reuse across calls, matching this codebase's "leak
   * long-lived state, don't over-engineer" convention), this genuinely
   * has no reason to survive past this one call. */
  pcre2_match_data *md = pcre2_match_data_create_from_pattern(re, NULL);
  int rc = pcre2_match(re, (PCRE2_SPTR)args[1].as.chars, (PCRE2_SIZE)args[1].aux, 0, 0, md, NULL);
  pcre2_match_data_free(md);
  return v_bool(rc >= 0);
}

static Value bi_regexp_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) creme_abort("regexp?: expected an argument");
  return v_bool(args[0].tag == T_BOX && args[0].aux == BOX_KIND_REGEX);
}

static pcre2_code *regex_arg(Value v, const char *who) {
  if (v.tag != T_BOX || v.aux != BOX_KIND_REGEX) creme_abort("%s: expected a regexp", who);
  return (pcre2_code *)v.as.ptr;
}

/* Matches `re` against subj[start..subj_len) once. Returns 1 with
 * match_start/match_end/groups set (a Scheme list of one T_STR per
 * capture group, INCLUDING group 0 -- the whole match -- as its own
 * first element, mirroring native's own found.to_a; a non-participating
 * optional group becomes #f), or 0 if there's no match at all. */
static int regex_match_once(VM *vm, pcre2_code *re, const char *subj, int subj_len, int start, int *match_start, int *match_end, Value *groups) {
  pcre2_match_data *md = pcre2_match_data_create_from_pattern(re, NULL);
  int rc = pcre2_match(re, (PCRE2_SPTR)subj, (PCRE2_SIZE)subj_len, (PCRE2_SIZE)start, 0, md, NULL);
  if (rc < 0) {
    pcre2_match_data_free(md);
    return 0;
  }
  PCRE2_SIZE *ov = pcre2_get_ovector_pointer(md);
  int npairs = rc > 0 ? rc : (int)pcre2_get_ovector_count(md);
  Value list = v_nil();
  for (int i = npairs - 1; i >= 0; i--) {
    PCRE2_SIZE s = ov[2 * i], e = ov[2 * i + 1];
    Value group;
    if (s == PCRE2_UNSET) {
      group = v_bool(0);
    } else {
      group = creme_bytes_value(subj + (int)s, (int)(e - s));
    }
    list = creme_cons(vm, group, list);
  }
  *match_start = (int)ov[0];
  *match_end = (int)ov[1];
  *groups = list;
  pcre2_match_data_free(md);
  return 1;
}

static Value bi_regexp_search(VM *vm, Value *args, int nargs) {
  if (nargs != 2 || args[1].tag != T_STR) creme_abort("regexp-search: expected (regexp string)");
  pcre2_code *re = regex_arg(args[0], "regexp-search");
  int ms, me;
  Value groups;
  if (!regex_match_once(vm, re, args[1].as.chars, args[1].aux, 0, &ms, &me, &groups)) return v_bool(0);
  return groups;
}

static Value bi_regexp_extract(VM *vm, Value *args, int nargs) {
  if (nargs != 2 || args[1].tag != T_STR) creme_abort("regexp-extract: expected (regexp string)");
  pcre2_code *re = regex_arg(args[0], "regexp-extract");
  const char *subj = args[1].as.chars;
  int len = args[1].aux;
  Value matches = v_nil();
  Value *collected = GC_MALLOC(sizeof(Value) * (size_t)(len + 1 ? len + 1 : 1));
  int n = 0;
  int start = 0;
  while (start <= len) {
    int ms, me;
    Value groups;
    if (!regex_match_once(vm, re, subj, len, start, &ms, &me, &groups)) break;
    collected[n++] = groups;
    start = me > ms ? me : me + 1;
  }
  for (int i = n - 1; i >= 0; i--) matches = creme_cons(vm, collected[i], matches);
  return matches;
}

/* regexp-replace/regexp-replace-all substitute the REPLACEMENT STRING
 * LITERALLY -- unlike native's own Crystal String#sub/#gsub, this
 * doesn't expand $1/$~[...]-style backreferences into captured groups.
 * A narrower, deliberate cut (mirrors this file's own header comment on
 * regexp/regexp-matches? being a narrow slice of the real (creme
 * regex)) -- nothing in this project's own reader.sld/spec suite needs
 * backreference expansion. */
static Value bi_regexp_replace(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 3 || args[1].tag != T_STR || args[2].tag != T_STR) creme_abort("regexp-replace: expected (regexp string string)");
  pcre2_code *re = regex_arg(args[0], "regexp-replace");
  const char *subj = args[2].as.chars;
  int len = args[2].aux;
  int ms, me;
  Value groups;
  if (!regex_match_once(vm, re, subj, len, 0, &ms, &me, &groups)) return args[2];
  const char *rep = args[1].as.chars;
  int rep_len = args[1].aux;
  int out_len = ms + rep_len + (len - me);
  char *out = GC_MALLOC((size_t)(out_len ? out_len : 1));
  memcpy(out, subj, (size_t)ms);
  memcpy(out + ms, rep, (size_t)rep_len);
  memcpy(out + ms + rep_len, subj + me, (size_t)(len - me));
  return v_str(out, out_len);
}

static Value bi_regexp_replace_all(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 3 || args[1].tag != T_STR || args[2].tag != T_STR) creme_abort("regexp-replace-all: expected (regexp string string)");
  pcre2_code *re = regex_arg(args[0], "regexp-replace-all");
  const char *subj = args[2].as.chars;
  int len = args[2].aux;
  const char *rep = args[1].as.chars;
  int rep_len = args[1].aux;

  char *out = NULL;
  int out_len = 0, out_cap = 0;
  int pos = 0;
  for (;;) {
    int ms, me;
    Value groups;
    if (!regex_match_once(vm, re, subj, len, pos, &ms, &me, &groups)) break;
    int prefix = ms - pos;
    int needed = out_len + prefix + rep_len;
    if (needed > out_cap) {
      out_cap = out_cap ? out_cap * 2 : 64;
      while (out_cap < needed) out_cap *= 2;
      out = GC_REALLOC(out, (size_t)out_cap);
    }
    memcpy(out + out_len, subj + pos, (size_t)prefix);
    out_len += prefix;
    memcpy(out + out_len, rep, (size_t)rep_len);
    out_len += rep_len;
    pos = me > ms ? me : me + 1;
    if (me == ms && me < len) {
      /* zero-length match: copy the one literal char we skipped over so
       * regexp-replace-all doesn't drop input, matching gsub's own
       * "advance past an empty match without consuming input" behavior. */
      if (out_len + 1 > out_cap) { out_cap = out_cap ? out_cap * 2 : 64; out = GC_REALLOC(out, (size_t)out_cap); }
      out[out_len++] = subj[me];
    }
    if (pos > len) break;
  }
  int tail = len - pos;
  if (tail > 0) {
    int needed = out_len + tail;
    if (needed > out_cap) {
      out_cap = needed;
      out = GC_REALLOC(out, (size_t)out_cap);
    }
    memcpy(out + out_len, subj + pos, (size_t)tail);
    out_len += tail;
  }
  return v_str(out ? out : GC_MALLOC(1), out_len);
}

static Value bi_regexp_split(VM *vm, Value *args, int nargs) {
  if (nargs != 2 || args[1].tag != T_STR) creme_abort("regexp-split: expected (regexp string)");
  pcre2_code *re = regex_arg(args[0], "regexp-split");
  const char *subj = args[1].as.chars;
  int len = args[1].aux;
  Value pieces = v_nil();
  Value *collected = GC_MALLOC(sizeof(Value) * (size_t)(len + 1));
  int n = 0;
  int pos = 0, last = 0;
  while (pos <= len) {
    int ms, me;
    Value groups;
    if (!regex_match_once(vm, re, subj, len, pos, &ms, &me, &groups)) break;
    int piece_len = ms - last;
    collected[n++] = creme_bytes_value(subj + last, piece_len);
    last = me;
    pos = me > ms ? me : me + 1;
  }
  int tail_len = len - last;
  collected[n++] = creme_bytes_value(subj + last, tail_len);
  for (int i = n - 1; i >= 0; i--) pieces = creme_cons(vm, collected[i], pieces);
  return pieces;
}

void creme_register_regex_builtins(VM *vm) {
  creme_register_builtin(vm, "regexp", bi_regexp);
  creme_register_builtin(vm, "regexp-matches?", bi_regexp_matches_p);
  creme_register_builtin(vm, "regexp?", bi_regexp_p);
  creme_register_builtin(vm, "regexp-search", bi_regexp_search);
  creme_register_builtin(vm, "regexp-extract", bi_regexp_extract);
  creme_register_builtin(vm, "regexp-replace", bi_regexp_replace);
  creme_register_builtin(vm, "regexp-replace-all", bi_regexp_replace_all);
  creme_register_builtin(vm, "regexp-split", bi_regexp_split);
}
