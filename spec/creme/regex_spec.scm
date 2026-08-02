;; ===========================================================================
;; A (creme spec)-based port of (creme regex)'s own cases (beyond
;; regexp/regexp-matches?, already covered by prim_call_spec.scm-style
;; reader.sld usage) -- see modules/creme/spec.sld's own header comment
;; for the framework this uses, and compiler_spec.scm's own header
;; comment for the general should-match-native? approach.
;;
;; regexp?/regexp-search/regexp-extract/regexp-replace/regexp-replace-all/
;; regexp-split used to be a deliberate icecreme gap -- icecreme/regex.c only had
;; regexp/regexp-matches? (just enough for reader.sld's own numeric-token
;; classification). Now built on a shared regex_match_once helper there.
;; regexp-replace/regexp-replace-all substitute their replacement string
;; LITERALLY, not expanding $1-style backreferences the way native's own
;; Crystal String#sub/#gsub does -- a narrower, deliberate cut (see that
;; file's own comment) -- so this file avoids backreference syntax in its
;; own replacement strings.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/regex_spec.scm
;;   ./bin/creme --self-hosted spec/creme/regex_spec.scm
;;   ./icecreme/icecreme spec/creme/regex_spec.scm
;; ===========================================================================

;; See compiler_spec.scm's own comment on why the full toolchain import
;; list is still needed here even though (creme compiler spec-helper)
;; already imports all of it for itself.
(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme regex) (creme peg) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(describe "(creme regex)"
  (it "regexp? distinguishes a compiled regexp from anything else"
    (should-match-native? '((regexp? (regexp "a+"))))
    (should-match-native? '((regexp? "a+"))))

  (it "regexp-search returns the whole match plus captured groups, or #f"
    (should-match-native? '((regexp-search (regexp "(\\d+)-(\\d+)") "abc 12-34 def")))
    (should-match-native? '((regexp-search (regexp "(\\d+)-(\\d+)") "no digits here"))))

  (it "regexp-extract finds every non-overlapping match"
    (should-match-native? '((regexp-extract (regexp "(\\d+)-(\\d+)") "1-2 and 3-4"))))

  (it "regexp-replace replaces only the first match"
    (should-match-native? '((regexp-replace (regexp "\\d+") "N" "a 1 b 2 c"))))

  (it "regexp-replace-all replaces every match"
    (should-match-native? '((regexp-replace-all (regexp "\\d+") "N" "a 1 b 2 c"))))

  (it "regexp-split splits on every match, keeping empty pieces between adjacent matches"
    (should-match-native? '((regexp-split (regexp ",") "a,b,,c")))))

(spec-summary!)
