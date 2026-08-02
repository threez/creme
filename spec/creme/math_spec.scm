;; ===========================================================================
;; A (creme spec)-based port of (creme math)'s own transcendental cases --
;; see modules/creme/spec.sld's own header comment for the framework this
;; uses, and compiler_spec.scm's own header comment for the general
;; should-match-native? approach.
;;
;; sin/cos/tan/asin/acos/atan/log/exp/log2/log10/atan2/pow/hypot/pi/e used
;; to be a deliberate cvm gap (only flonum->bits/bits->flonum existed
;; there) -- now thin libm wrappers in cvm/builtins.c (cvm already links
;; libm for the numeric tower's own use).
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/math_spec.scm
;;   ./bin/creme --self-hosted spec/creme/math_spec.scm
;;   ./cvm/cvm spec/creme/math_spec.scm
;; ===========================================================================

;; See compiler_spec.scm's own comment on why the full toolchain import
;; list is still needed here even though (creme compiler spec-helper)
;; already imports all of it for itself.
(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme math) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(describe "(creme math)"
  (it "sin/cos/tan/asin/acos/atan of familiar values"
    (should-match-native? '((sin 0)))
    (should-match-native? '((cos 0)))
    (should-match-native? '((tan 0)))
    (should-match-native? '((asin 0)))
    (should-match-native? '((acos 1)))
    (should-match-native? '((atan 0))))

  (it "log/exp are inverses, and log's optional 2nd argument is an explicit base"
    (should-match-native? '((log e)))
    (should-match-native? '((log (exp 1))))
    (should-match-native? '((log 8 2))))

  (it "log2/log10"
    (should-match-native? '((log2 8)))
    (should-match-native? '((log10 100))))

  (it "atan2/pow/hypot"
    (should-match-native? '((atan2 1 1)))
    (should-match-native? '((pow 2 10)))
    (should-match-native? '((hypot 3 4))))

  (it "pi/e are bound to the expected constants"
    (should-match-native? '((> pi 3.14)))
    (should-match-native? '((< pi 3.15)))
    (should-match-native? '((> e 2.71)))
    (should-match-native? '((< e 2.72)))
    (should-match-native? '(pi))
    (should-match-native? '(e)))

  (it "raises when given a non-number"
    (should-raise? (lambda () (should-match-native? '((sin "x"))))))

  (it "round-trips a float through its raw IEEE754 bit pattern"
    ;; This one's an exact integer bit pattern, not a float -- direct
    ;; should-equal? against the known-correct literal (same as the
    ;; Crystal reference spec's own hardcoded expectation), not
    ;; should-match-native?, since there's no floating-point formatting
    ;; ambiguity to route around here.
    (should-equal? (flonum->bits 1.0) 4607182418800017408)
    (should-match-native? '((bits->flonum (flonum->bits 3.14))))
    (should-match-native? '((bits->flonum (flonum->bits +inf.0))))
    (should-match-native? '((bits->flonum (flonum->bits -inf.0))))
    (should-match-native? '((bits->flonum (flonum->bits +nan.0))))))

(spec-summary!)
