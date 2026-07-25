/* (creme regex) — see regex.h.
 *
 * Only exists so the self-hosted reader (modules/creme/compiler/
 * reader.sld) can run under cvm: it uses `regexp`/`regexp-matches?` to
 * classify numeric tokens (int/rational/float/complex), and until this
 * file existed cvm had no regex support at all, making that library
 * unloadable here. Deliberately narrow: just these two names. Backed by
 * PCRE2 (the same regex flavor the real Crystal `Regex` class itself
 * uses), specifically so reader.sld's own patterns -- written with PCRE-
 * style `\A`/`\z` string anchors -- work completely unchanged under cvm;
 * a POSIX <regex.h> backend would have needed those patterns rewritten
 * (POSIX ERE has no `\A`/`\z`), which risked the shared reader.sld file
 * behaving subtly differently under the two backends. No other
 * (creme regex) surface (regexp-match/replace/etc.) is implemented --
 * nothing else in the self-hosted compiler toolchain needs it. */
#define PCRE2_CODE_UNIT_WIDTH 8
#include <pcre2.h>

#include "regex.h"

static Value bi_regexp(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 1 || args[0].tag != T_STR) cvm_abort("regexp: expected a pattern string");
  int errcode;
  PCRE2_SIZE erroffset;
  pcre2_code *re = pcre2_compile((PCRE2_SPTR)args[0].as.str.chars, (PCRE2_SIZE)args[0].as.str.len, 0, &errcode, &erroffset, NULL);
  if (!re) {
    PCRE2_UCHAR errbuf[256];
    pcre2_get_error_message(errcode, errbuf, sizeof(errbuf));
    cvm_abort("regexp: invalid pattern: %s", (char *)errbuf);
  }
  return v_box(re, BOX_KIND_REGEX);
}

static Value bi_regexp_matches_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 2 || args[0].tag != T_BOX || args[0].as.box.kind != BOX_KIND_REGEX || args[1].tag != T_STR) {
    cvm_abort("regexp-matches?: expected (regexp string)");
  }
  pcre2_code *re = (pcre2_code *)args[0].as.box.ptr;
  /* Short-lived scratch space, freed immediately after use -- unlike the
   * compiled pattern itself (`re`, GC-owned via v_box, intentionally kept
   * alive for reuse across calls, matching this codebase's "leak
   * long-lived state, don't over-engineer" convention), this genuinely
   * has no reason to survive past this one call. */
  pcre2_match_data *md = pcre2_match_data_create_from_pattern(re, NULL);
  int rc = pcre2_match(re, (PCRE2_SPTR)args[1].as.str.chars, (PCRE2_SIZE)args[1].as.str.len, 0, 0, md, NULL);
  pcre2_match_data_free(md);
  return v_bool(rc >= 0);
}

void cvm_register_regex_builtins(VM *vm) {
  cvm_register_builtin(vm, "regexp", bi_regexp);
  cvm_register_builtin(vm, "regexp-matches?", bi_regexp_matches_p);
}
