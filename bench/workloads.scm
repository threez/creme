; Portable R7RS micro-benchmark bodies: pure (scheme base)/(scheme write)/
; (scheme inexact) usage only, so they run unmodified on any conformant R7RS
; implementation (verified against Racket's `#lang r7rs`).
;
; Workloads, chosen to exercise different interpreter hot paths:
;   - fib: deep non-tail recursion (stack/call overhead)
;   - sum-to: tail-recursive accumulation (trampoline/TCO)
;   - list building + reverse + length (allocation, list traversal)
;   - vector fill + sum (mutable array access)
;   - string building via a string output port (growable-buffer writes)
;   - tak: the Gabriel Takeuchi benchmark, triply-nested non-tail recursion
;     over small integers (call dispatch + integer arithmetic, no allocation)
;   - nqueens: backtracking search that conses a growing position list and
;     walks it per candidate (recursion + allocation + list traversal together)
;
; This file has no (import ...) line of its own and is never run directly —
; it's just the workload definitions, spliced in via (include "workloads.scm")
; by bench/creme.scm, bench/racket.scm, and bench/prof.scm, so the exact same
; benchmarked code runs under all three, with a single source of truth
; instead of copies to keep in sync. bench/creme.scm and bench/racket.scm
; also (include "workloads-demo.scm") right after this one, to print each
; workload's own timed result — bench/prof.scm includes only this file, since
; it profiles these same definitions itself and has no use for that printed
; demo run (see workloads-demo.scm's own header comment).

(define (fib n)
  (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))

(define (sum-to n acc)
  (if (= n 0) acc (sum-to (- n 1) (+ acc n))))

(define (build-list n)
  (let loop ((i 0) (acc '()))
    (if (= i n) acc (loop (+ i 1) (cons i acc)))))

(define (vector-sum-test n)
  (let ((v (make-vector n 0)))
    (let loop ((i 0))
      (if (< i n)
          (begin (vector-set! v i (* i 2)) (loop (+ i 1)))))
    (let loop ((i 0) (acc 0))
      (if (= i n) acc (loop (+ i 1) (+ acc (vector-ref v i)))))))

(define (string-build-test n)
  (let ((port (open-output-string)))
    (let loop ((i 0))
      (if (= i n)
          (string-length (get-output-string port))
          (begin (write-string "x" port) (loop (+ i 1)))))))

(define (tak x y z)
  (if (not (< y x))
      z
      (tak (tak (- x 1) y z)
           (tak (- y 1) z x)
           (tak (- z 1) x y))))

; Counts all solutions to the n-queens problem. `positions` is the list of
; already-placed queens' columns, most recent (nearest row) first; `dist` is
; the row distance from `col`'s row to the head of `positions`, so a diagonal
; conflict is (= (abs (- placed-col col)) dist).
(define (nqueens board-size)
  (define (safe? col positions dist)
    (cond ((null? positions) #t)
          ((= (car positions) col) #f)
          ((= (abs (- (car positions) col)) dist) #f)
          (else (safe? col (cdr positions) (+ dist 1)))))
  (define (place row positions)
    (if (= row board-size)
        1
        (let loop ((col 0) (count 0))
          (if (= col board-size)
              count
              (loop (+ col 1)
                    (if (safe? col positions 1)
                        (+ count (place (+ row 1) (cons col positions)))
                        count))))))
  (place 0 '()))
