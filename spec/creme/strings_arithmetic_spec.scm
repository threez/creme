;; ===========================================================================
;; A (creme spec)-based port of the remaining (scheme base) string/
;; symbol/boolean cases (base/strings.cr) and arithmetic cases
;; (base/arithmetic.cr) -- see modules/creme/spec.sld's own header
;; comment for the framework this uses, and compiler_spec.scm's own
;; header comment for the general should-match-native? approach.
;;
;; string<?/>/<=?/>=?, symbol=?, boolean=?, string-map, string-copy!,
;; string-fill!, string->vector, vector->string used to be a deliberate
;; cvm gap in base/strings.cr. truncate-quotient/-remainder,
;; floor-quotient/-remainder, truncate//floor/, gcd, lcm, expt,
;; exact-integer-sqrt used to be the same in base/arithmetic.cr.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/strings_arithmetic_spec.scm
;;   ./bin/creme --self-hosted spec/creme/strings_arithmetic_spec.scm
;;   ./cvm/cvm spec/creme/strings_arithmetic_spec.scm
;; ===========================================================================

;; See compiler_spec.scm's own comment on why the full toolchain import
;; list is still needed here even though (creme compiler spec-helper)
;; already imports all of it for itself. (scheme char) is for
;; char-upcase, used by one string-map case below.
(import (scheme base) (scheme char) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(describe "(scheme base) remaining string/symbol/boolean cases"
  (it "string<?/>/<=?/>=? compare lexicographically, case-sensitively"
    (should-match-native? '((string<? "a" "b" "c")))
    (should-match-native? '((string>? "c" "b" "a")))
    (should-match-native? '((string<=? "a" "a" "b")))
    (should-match-native? '((string>=? "b" "a" "a")))
    (should-match-native? '((string<? "abc" "abd"))))

  (it "symbol=?/boolean=? compare by identity of name/value"
    (should-match-native? '((symbol=? 'a 'a 'a)))
    (should-match-native? '((symbol=? 'a 'b)))
    (should-match-native? '((boolean=? #t #t)))
    (should-match-native? '((boolean=? #t #f))))

  (it "string-map applies a proc across parallel strings up to the shortest"
    (should-match-native? '((string-map char-upcase "abc")))
    (should-match-native? '((string-map (lambda (a b) (if (char=? a b) #\y #\n)) "abcd" "abzd"))))

  (it "string-copy! mutates a range of the destination string in place"
    (should-match-native? '((define s (string-copy "hello world")) (string-copy! s 0 "HELLO") s))
    (should-match-native? '((define s (string-copy "hello world")) (string-copy! s 6 "world" 0 3) s)))

  (it "string-fill! fills a range with the given char"
    (should-match-native? '((define s (make-string 5 #\x)) (string-fill! s #\y 1 3) s)))

  (it "string->vector/vector->string round-trip"
    (should-match-native? '((string->vector "abc")))
    (should-match-native? '((vector->string (vector #\x #\y #\z))))
    (should-match-native? '((string->vector "abcde" 1 3)))))

(describe "(scheme base) remaining arithmetic cases"
  (it "truncate-quotient/truncate-remainder match quotient/remainder"
    (should-match-native? '((truncate-quotient 7 2)))
    (should-match-native? '((truncate-remainder 7 2)))
    (should-match-native? '((truncate-quotient -7 2)))
    (should-match-native? '((truncate-remainder -7 2))))

  (it "floor-quotient/floor-remainder round toward negative infinity"
    (should-match-native? '((floor-quotient -7 2)))
    (should-match-native? '((floor-remainder -7 2)))
    (should-match-native? '((floor-quotient 7 2)))
    (should-match-native? '((floor-remainder 7 2))))

  (it "truncate//floor/ return both parts via values"
    (should-match-native? '((call-with-values (lambda () (truncate/ 7 2)) list)))
    (should-match-native? '((call-with-values (lambda () (floor/ -7 2)) list))))

  (it "gcd/lcm, including their 0-argument identities"
    (should-match-native? '((gcd)))
    (should-match-native? '((lcm)))
    (should-match-native? '((gcd 12 18)))
    (should-match-native? '((lcm 4 6)))
    (should-match-native? '((gcd -12 18))))

  (it "expt stays exact for an exact base/exponent, including a negative exponent"
    (should-match-native? '((expt 2 10)))
    (should-match-native? '((expt 2 -3)))
    (should-match-native? '((expt 2.0 0.5))))

  (it "exact-integer-sqrt returns the integer root and remainder via values"
    (should-match-native? '((call-with-values (lambda () (exact-integer-sqrt 17)) list)))
    (should-match-native? '((call-with-values (lambda () (exact-integer-sqrt 16)) list)))))

(spec-summary!)
