; A tiny grade book showcasing exact rational arithmetic (scores stay exact
; fractions, never lossy floats) alongside a hash table for per-student
; lookup, values/call-with-values for a two-value summary, and a couple of
; small local list helpers for the reporting pass.

(import (scheme base) (scheme write) (creme hash-table))

(define (fold-left-list f init lst)
  (if (null? lst) init (fold-left-list f (f init (car lst)) (cdr lst))))
(define (filter-list pred lst)
  (cond ((null? lst) '())
        ((pred (car lst)) (cons (car lst) (filter-list pred (cdr lst))))
        (else (filter-list pred (cdr lst)))))
(define (any-list pred lst)
  (cond ((null? lst) #f)
        ((pred (car lst)) #t)
        (else (any-list pred (cdr lst)))))

(define grades (make-hash-table))

(define (record! name score out-of)
  (hash-table-set! grades name (/ score out-of)))

(record! "alice" 27 30)
(record! "bob" 18 20)
(record! "carol" 91 100)

(define (student-grade name)
  (hash-table-ref grades name 0))

(display "alice: ") (display (student-grade "alice")) (newline)
(display "bob:   ") (display (student-grade "bob")) (newline)
(display "carol: ") (display (student-grade "carol")) (newline)

; class-average returns two values: the exact average and its float form,
; via values/call-with-values rather than a two-element list.
(define (class-average)
  (define scores (hash-table-values grades))
  (define total (fold-left-list + 0 scores))
  (define avg (/ total (length scores))) ; stays an exact rational
  (values avg (inexact avg)))

(call-with-values class-average
  (lambda (exact-avg float-avg)
    (display "class average (exact): ") (display exact-avg) (newline)
    (display "class average (~):     ") (display float-avg) (newline)))

; honor-roll: students at or above 9/10.
(define passing-threshold (/ 9 10))
(define names (hash-table-keys grades))
(define honor-roll (filter-list (lambda (n) (>= (student-grade n) passing-threshold)) names))
(display "honor roll: ") (display honor-roll) (newline)
(display "anyone below threshold? ") (display (any-list (lambda (n) (< (student-grade n) passing-threshold)) names)) (newline)
