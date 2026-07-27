;; ===========================================================================
;; A (creme spec)-based port of (creme random)'s own cases -- see
;; modules/creme/spec.sld's own header comment for the framework this
;; uses.
;;
;; random-real/random-integer/random-seed!/random-choice/random-shuffle
;; used to be a deliberate cvm gap (entirely absent). cvm's own PRNG
;; (a splitmix64 generator, cvm/builtins.c) is deliberately NOT bit-for-
;; bit compatible with Crystal's own Random (PCG-based) -- nothing
;; observes cvm's sequence against a real Crystal process, so that's not
;; a goal. Unlike this directory's other spec files, this one does NOT
;; use should-match-native? at all: every case runs directly against
;; whichever single backend is executing this file (native/self-hosted/
;; cvm) and asserts range/membership/determinism properties instead of
;; an exact expected value -- appropriate for a genuinely random source.
;; random-seed!'s determinism case seeds and draws TWICE within that one
;; running interpreter, not by comparing across two different compilers.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/random_spec.scm
;;   ./bin/creme --self-hosted spec/creme/random_spec.scm
;;   ./cvm/cvm spec/creme/random_spec.scm
;; ===========================================================================

(import (scheme base) (scheme write) (creme random) (creme spec))

(describe "(creme random)"
  (it "random-real returns a float in [0, 1)"
    (let ((r (random-real)))
      (should-be-true? (>= r 0.0))
      (should-be-true? (< r 1.0))))

  (it "random-integer returns an exact integer in [0, n)"
    (let ((n (random-integer 1000)))
      (should-be-true? (>= n 0))
      (should-be-true? (< n 1000))))

  (it "random-seed! makes random-integer deterministic"
    (random-seed! 42)
    (let ((a (random-integer 1000000)))
      (random-seed! 42)
      (let ((b (random-integer 1000000)))
        (should-equal? a b))))

  (it "random-choice picks a member of the given list"
    (should-be-true? (member (random-choice '(a b c d e)) '(a b c d e))))

  (it "random-shuffle returns a permutation of the same elements"
    (let ((shuffled (random-shuffle '(1 2 3 4 5))))
      (should-equal? (length shuffled) 5)
      (should-be-true? (member 1 shuffled))
      (should-be-true? (member 2 shuffled))
      (should-be-true? (member 3 shuffled))
      (should-be-true? (member 4 shuffled))
      (should-be-true? (member 5 shuffled)))))

(spec-summary!)
