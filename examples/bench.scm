; Portable R7RS micro-benchmark: pure (scheme base)/(scheme write)/
; (scheme inexact)/(scheme time) usage only, so it runs unmodified on any
; conformant R7RS implementation (verified against Racket's `#lang r7rs`).
; Prints each workload's result plus its wall-clock time via
; (scheme time)'s current-second (R7RS's minimal time contract).
;
; Workloads, chosen to exercise different interpreter hot paths:
;   - fib: deep non-tail recursion (stack/call overhead)
;   - sum-to: tail-recursive accumulation (trampoline/TCO)
;   - list building + reverse + length (allocation, list traversal)
;   - vector fill + sum (mutable array access)
;   - string building via string-append in a loop (string allocation)

(import (scheme base) (scheme write) (scheme inexact) (scheme time))

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
  (let loop ((i 0) (s ""))
    (if (= i n) (string-length s) (loop (+ i 1) (string-append s "x")))))

(define (timed-run name thunk)
  (let* ((start (current-second))
         (result (thunk))
         (elapsed (- (current-second) start)))
    (display name) (display " = ") (display result)
    (display "  (") (display elapsed) (display "s)")
    (newline)
    result))

(define total-start (current-second))

(timed-run "fib(27)" (lambda () (fib 27)))
(timed-run "sum-to(2000000)" (lambda () (sum-to 2000000 0)))
(timed-run "build-list(200000) length+reverse" (lambda () (length (reverse (build-list 200000)))))
(timed-run "vector-sum-test(500000)" (lambda () (vector-sum-test 500000)))
(timed-run "string-build-test(4000) length" (lambda () (string-build-test 4000)))

(display "total = ") (display (- (current-second) total-start)) (display "s") (newline)
