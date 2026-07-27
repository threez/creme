;; ===========================================================================
;; A (creme spec)-based port of (scheme char)'s own cases -- see
;; modules/creme/spec.sld's own header comment for the framework this
;; uses, and compiler_spec.scm's own header comment for the general
;; should-match-native? approach.
;;
;; char-alphabetic?/char-numeric?/char-whitespace?/char-upper-case?/
;; char-lower-case?/char-foldcase/digit-value/char-ci=?<>/string-ci=?<>/
;; string-foldcase used to be a deliberate cvm gap (only char-upcase/
;; char-downcase/string-upcase/string-downcase existed there) -- now
;; implemented in cvm/builtins.c (ASCII-only, matching those existing
;; ones' own documented scope) and cvm/strings.c (string-foldcase, same
;; function as string-downcase).
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/char_spec.scm
;;   ./bin/creme --self-hosted spec/creme/char_spec.scm
;;   ./cvm/cvm spec/creme/char_spec.scm
;; ===========================================================================

;; See compiler_spec.scm's own comment on why the full toolchain import
;; list is still needed here even though (creme compiler spec-helper)
;; already imports all of it for itself.
(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (scheme char) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(describe "(scheme char)"
  (it "char classification predicates"
    (should-match-native? '((char-alphabetic? #\a)))
    (should-match-native? '((char-alphabetic? #\5)))
    (should-match-native? '((char-numeric? #\5)))
    (should-match-native? '((char-numeric? #\a)))
    (should-match-native? '((char-whitespace? #\space)))
    (should-match-native? '((char-whitespace? #\a)))
    (should-match-native? '((char-upper-case? #\A)))
    (should-match-native? '((char-upper-case? #\a)))
    (should-match-native? '((char-lower-case? #\a)))
    (should-match-native? '((char-lower-case? #\A))))

  (it "digit-value returns a digit's numeric value, or #f for a non-digit"
    (should-match-native? '((digit-value #\7)))
    (should-match-native? '((digit-value #\a))))

  (it "char-foldcase behaves like char-downcase"
    (should-match-native? '((char-foldcase #\A)))
    (should-match-native? '((char-foldcase #\a))))

  (it "char-ci=?/</>/<=/>= compare case-insensitively"
    (should-match-native? '((char-ci=? #\A #\a)))
    (should-match-native? '((char-ci<? #\a #\B)))
    (should-match-native? '((char-ci>? #\B #\a)))
    (should-match-native? '((char-ci<=? #\A #\a)))
    (should-match-native? '((char-ci>=? #\a #\A))))

  (it "string-foldcase behaves like string-downcase"
    (should-match-native? '((string-foldcase "ABC"))))

  (it "string-ci=?/</>/<=/>= compare case-insensitively"
    (should-match-native? '((string-ci=? "AbC" "abc")))
    (should-match-native? '((string-ci=? "AbC" "abcd")))
    (should-match-native? '((string-ci<? "abc" "ABD")))
    (should-match-native? '((string-ci>? "ABD" "abc")))
    (should-match-native? '((string-ci<=? "abc" "ABC")))
    (should-match-native? '((string-ci>=? "ABC" "abc")))))

(spec-summary!)
