;; ===========================================================================
;; A (creme spec)-based port of (scheme inexact)'s own sqrt/nan?/
;; infinite?/finite? cases -- see modules/creme/spec.sld's own header
;; comment for the framework this uses, and compiler_spec.scm's own
;; header comment for the general should-match-native? approach.
;;
;; sqrt/nan?/infinite?/finite? used to be a deliberate icecreme gap (entirely
;; absent). sqrt has an exact perfect-square fast path ((sqrt 4) is exact
;; 2, not inexact 2.0) and returns a complex value for a negative real
;; input, mirroring native's own (scheme inexact) sqrt exactly.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/inexact_spec.scm
;;   ./bin/creme --self-hosted spec/creme/inexact_spec.scm
;;   ./icecreme/icecreme spec/creme/inexact_spec.scm
;; ===========================================================================

;; See compiler_spec.scm's own comment on why the full toolchain import
;; list is still needed here even though (creme compiler spec-helper)
;; already imports all of it for itself.
(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (scheme inexact) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(describe "(scheme inexact)"
  (it "sqrt of a perfect square stays exact"
    (should-match-native? '((sqrt 4)))
    (should-match-native? '((sqrt 9))))

  (it "sqrt of a non-perfect-square positive integer is inexact"
    (should-match-native? '((sqrt 2))))

  (it "sqrt of a negative real returns a complex value"
    (should-match-native? '((sqrt -4))))

  (it "nan?/infinite?/finite? classify float values"
    (should-match-native? '((nan? +nan.0)))
    (should-match-native? '((nan? 1.0)))
    (should-match-native? '((infinite? +inf.0)))
    (should-match-native? '((infinite? 1.0)))
    (should-match-native? '((finite? 3.0)))
    (should-match-native? '((finite? +inf.0)))
    (should-match-native? '((finite? 3)))))

(spec-summary!)
