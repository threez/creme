;; ===========================================================================
;; A (creme spec)-based port of (creme math)'s own transcendental cases --
;; see modules/creme/spec.sld's own header comment for the framework this
;; uses, and compiler_spec.scm's own header comment for the general
;; should-match-native? approach.
;;
;; sin/cos/tan/asin/acos/atan/log/exp/log2/log10/atan2/pow/hypot/pi/e used
;; to be a deliberate icecreme gap (only flonum->bits/bits->flonum existed
;; there) -- now thin libm wrappers in icecreme/builtins.c (icecreme already links
;; libm for the numeric tower's own use).
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/math_spec.scm
;;   ./bin/creme --self-hosted spec/creme/math_spec.scm
;;   ./icecreme/icecreme spec/creme/math_spec.scm
;; ===========================================================================

;; See compiler_spec.scm's own comment on why the full toolchain import
;; list is still needed here even though (creme compiler spec-helper)
;; already imports all of it for itself.
(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (scheme complex) (creme math) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
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

;; sin/cos/tan/asin/acos/atan/exp/log now accept a genuine complex
;; argument (via icecreme/builtins.c's cd_* helpers, mirroring native's
;; own Creme::ComplexMath exactly), and asin/acos/log/sqrt additionally
;; extend a real argument's domain into the complex plane for the cases
;; that are genuinely complex-valued (out-of-range asin/acos, negative
;; log) instead of silently returning NaN. expt's negative-real-base +
;; non-integer-exponent case is fixed the same way.
(describe "complex-aware transcendentals"
  (it "sin/cos/tan/exp/atan accept a genuine complex argument"
    (should-match-native? '((sin 1+2i)))
    (should-match-native? '((cos 1+2i)))
    (should-match-native? '((tan 1+2i)))
    (should-match-native? '((exp 1+1i)))
    (should-match-native? '((atan 1+1i))))

  (it "log accepts a genuine complex argument, and extends to negative reals"
    (should-match-native? '((log 1+1i)))
    (should-match-native? '((log -4)))
    (should-match-native? '((log 0))) ; unaffected: still -inf.0, not complex
    (should-match-native? '((log 1 -1)))) ; explicit-base 2-arg form stays real-only (NaN)

  (it "asin/acos extend to an out-of-range real argument, and accept a complex one"
    (should-match-native? '((asin 2)))
    (should-match-native? '((acos 2)))
    (should-match-native? '((asin 1+1i)))
    (should-match-native? '((acos 1+1i)))
    (should-match-native? '((asin 0.5))) ; unaffected: in-range real stays real
    (should-match-native? '((acos 0.5))))

  (it "expt: a negative real base with a non-integer exponent goes complex instead of NaN"
    (should-match-native? '((expt -8 1/3)))
    (should-match-native? '((expt -8.0 0.5))))

  (it "expt: a negative real base with an integer-valued exponent still stays real"
    (should-match-native? '((expt -8.0 2.0)))
    (should-match-native? '((expt -8 3))))

  (it "expt: a genuinely complex base or exponent"
    (should-match-native? '((real-part (expt 1+1i 2))))
    (should-match-native? '((imag-part (expt 1+1i 2))))))

;; Complex division and magnitude stay exact when every component is
;; exact, instead of always forcing an inexact float result — see
;; src/creme/eval/builtin_helpers.cr's complex_div and
;; src/creme/modules/scheme/complex.cr's magnitude, mirrored here in
;; icecreme/vm.c's complex_div and icecreme/builtins.c's bi_magnitude.
;; angle/make-polar stay inexact always (genuinely transcendental, not a
;; remaining gap — see README Known caveats).
(describe "complex division / magnitude stay exact when possible"
  (it "division stays exact when both operands are exact"
    (should-match-native? '((/ (make-rectangular 1 2) (make-rectangular 1 0))))
    (should-match-native? '((/ (make-rectangular 1 2) (make-rectangular 3 4)))))

  (it "division falls back to inexact once either operand has an inexact component"
    (should-match-native? '((/ (make-rectangular 1.0 2) (make-rectangular 1 0)))))

  (it "division by a genuine complex zero raises"
    (should-raise? (lambda () (should-match-native? '((/ (make-rectangular 1 2) (make-rectangular 0 0)))))))

  (it "magnitude stays exact for a perfect-square sum of squares"
    (should-match-native? '((magnitude (make-rectangular 3 4)))))

  (it "magnitude falls back to inexact once the sum of squares isn't a perfect-square integer"
    (should-match-native? '((magnitude (make-rectangular 1 1))))
    (should-match-native? '((magnitude (make-rectangular 3.0 4))))
    (should-match-native? '((magnitude (make-rectangular 3/2 2))))))

(spec-summary!)
