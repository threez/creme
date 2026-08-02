;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/r7rs/ch06_01_equivalence_spec.cr's
;; own cases -- see modules/creme/spec.sld's own header comment for the
;; framework this uses. The original Crystal spec evaluated each case's
;; Scheme source via a fresh sub-interpreter (run(src)/w(src)) since it was
;; testing a Scheme interpreter from OUTSIDE, as Crystal code; here, running
;; directly as Scheme, each case's forms are written and asserted directly
;; via should-equal?/should-eqv?/should-be-true?/should-be-false? instead.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/r7rs/ch06_01_equivalence_spec.scm
;;   ./bin/creme --self-hosted spec/creme/r7rs/ch06_01_equivalence_spec.scm
;;   ./cvm/cvm spec/creme/r7rs/ch06_01_equivalence_spec.scm
;; ===========================================================================

(import (scheme base) (creme spec))

(describe "R7RS §6.1 Equivalence predicates (eqv?)"
  (it "is #t for identical booleans, symbols, exact numerically-equal numbers, and ()"
    (should-be-true? (eqv? 'a 'a))
    (should-be-true? (eqv? 2 2))
    (should-be-true? (eqv? '() '()))
    (should-be-true? (eqv? 100000000 100000000)))

  (it "is #f for an exact and an inexact number even if numerically equal, and for freshly-cons'd pairs"
    (should-be-false? (eqv? 2 2.0))
    (should-be-false? (eqv? (cons 1 2) (cons 1 2))))

  (it "is #f for different-bodied lambdas, and unspecified for identically-bodied ones"
    (should-be-false? (eqv? (lambda () 1) (lambda () 2))))

  (it "recognizes a procedure as eqv? to itself"
    (let ((p (lambda (x) x)))
      (should-be-true? (eqv? p p))))

  (it "distinguishes procedures with distinct captured state (gen-counter) but may conflate operationally-equivalent ones (gen-loser)"
    (let ()
      (define (gen-counter)
        (let ((n 0)) (lambda () (set! n (+ n 1)) n)))
      (define g (gen-counter))
      (should-be-true? (eqv? g g))
      (should-be-false? (eqv? (gen-counter) (gen-counter)))))

  (it "(eqv? 0.0 -0.0) is #f, since negative zero is distinguished from positive zero"
    (should-be-false? (eqv? 0.0 -0.0))))

(describe "R7RS §6.1 Equivalence predicates (eq?)"
  (it "is guaranteed consistent with eqv? on symbols, booleans, (), pairs, records, non-empty strings/vectors/bytevectors"
    (should-be-true? (eq? 'a 'a))
    (should-be-true? (eq? '() '()))
    (should-be-true? (let ((x (list 'a))) (eq? x x))))

  (it "returns #t for the same procedure object"
    (should-be-true? (eq? car car))))

(describe "R7RS §6.1 Equivalence predicates (equal?)"
  (it "recursively compares pairs/vectors/strings/bytevectors as ordered trees"
    (should-be-true? (equal? 'a 'a))
    (should-be-true? (equal? (list 'a (list 'b) 'c) (list 'a (list 'b) 'c)))
    (should-be-true? (equal? "abc" "abc"))
    (should-be-true? (equal? 2 2))
    (should-be-true? (equal? (make-vector 5 'a) (make-vector 5 'a))))

  (it "falls back to eqv?'s behavior for booleans/symbols/numbers/characters/ports/procedures/the empty list"
    (should-be-true? (equal? car car))
    (should-be-true? (equal? #t #t)))

  (it "terminates even on circular data structures, comparing equal circular lists as equal"
    (let ((a (list 1 2)) (b (list 1 2)))
      (set-cdr! (cdr a) a)
      (set-cdr! (cdr b) b)
      (should-be-true? (equal? a b))))

  (it "terminates on circular structures with differing content, correctly comparing them unequal"
    (let ((a (list 1 2)) (b (list 1 3)))
      (set-cdr! (cdr a) a)
      (set-cdr! (cdr b) b)
      (should-be-false? (equal? a b)))))

(spec-summary!)
