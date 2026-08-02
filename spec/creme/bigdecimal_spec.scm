;; ===========================================================================
;; A (creme spec)-based port of (creme bigdecimal)'s own cases
;; (spec/scheme/modules/creme/big_decimal_spec.cr) -- see
;; modules/creme/spec.sld's own header comment for the framework this
;; uses, and compiler_spec.scm's own header comment for the general
;; should-match-native? approach.
;;
;; (creme bigdecimal) used to be entirely absent from icecreme. Crystal's own
;; `require "big"` (BigDecimal) is standard library, not an external
;; shard (see shard.yml) -- backed here (icecreme/bigdecimal.c) by a small
;; hand-rolled decimal type on top of GMP's arbitrary-precision mpz_t
;; (already linked, used for T_RATIONAL): an integer mantissa plus a
;; decimal scale, Java-BigDecimal-style, exact by construction --
;; deliberately NOT GMP's own mpf_t (arbitrary-precision BINARY floating
;; point, which would silently drift from Crystal's own exact-decimal
;; semantics the same way an ordinary float would). Like native, this is
;; a standalone boxed type never hooked into the numeric tower (+/-/*
;; never promote to/from it) -- see bigdecimal.c's own header comment
;; for the one genuinely approximate piece (division: computed to a
;; generous fixed extra precision, then trailing zeros trimmed back off
;; for an exact/terminating quotient, same as every case tested here).
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/bigdecimal_spec.scm
;;   ./bin/creme --self-hosted spec/creme/bigdecimal_spec.scm
;;   ./icecreme/icecreme spec/creme/bigdecimal_spec.scm
;; ===========================================================================

;; See compiler_spec.scm's own comment on why the full toolchain import
;; list is still needed here even though (creme compiler spec-helper)
;; already imports all of it for itself.
(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme bigdecimal) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(describe "(creme bigdecimal)"
  (it "parses and adds"
    (should-match-native?
     '((bigdecimal->string (bigdecimal-add (string->bigdecimal "1.1") (string->bigdecimal "2.2"))))))

  (it "subtracts, multiplies, divides"
    (should-match-native? '((bigdecimal->string (bigdecimal-sub (string->bigdecimal "5") (string->bigdecimal "2")))))
    (should-match-native? '((bigdecimal->string (bigdecimal-mul (string->bigdecimal "2") (string->bigdecimal "3")))))
    (should-match-native? '((bigdecimal->string (bigdecimal-div (string->bigdecimal "6") (string->bigdecimal "2"))))))

  (it "compares"
    (should-match-native? '((bigdecimal<? (string->bigdecimal "1") (string->bigdecimal "2"))))
    (should-match-native? '((bigdecimal=? (string->bigdecimal "1.0") (string->bigdecimal "1.0"))))
    (should-match-native? '((bigdecimal>? (string->bigdecimal "5") (string->bigdecimal "3"))))
    (should-match-native? '((bigdecimal-compare (string->bigdecimal "5") (string->bigdecimal "5")))))

  (it "raises on division by zero"
    (should-raise? (lambda () (bigdecimal-div (string->bigdecimal "1") (string->bigdecimal "0")))))

  (it "raises on invalid decimal strings"
    (should-raise? (lambda () (string->bigdecimal "not-a-number"))))

  (it "negates, checks zero-ness, and converts an exact integer"
    (should-match-native? '((bigdecimal->string (bigdecimal-neg (string->bigdecimal "3.5")))))
    (should-match-native? '((bigdecimal-zero? (string->bigdecimal "0.00"))))
    (should-match-native? '((bigdecimal-zero? (string->bigdecimal "0.01"))))
    (should-match-native? '((bigdecimal->string (integer->bigdecimal 42)))))

  (it "division that terminates exactly (a non-integer quotient)"
    (should-match-native? '((bigdecimal->string (bigdecimal-div (string->bigdecimal "1") (string->bigdecimal "4"))))))

  (it "bigdecimal? distinguishes a bigdecimal from an ordinary number"
    (should-match-native? '((bigdecimal? (string->bigdecimal "5"))))
    (should-match-native? '((bigdecimal? 5)))))

(spec-summary!)
