#lang r7rs
;; Racket counterpart of competition/bench.scm's own workload run: same
;; imports, same (include "../../bench/workloads.scm")/(include
;; "../../bench/workloads-demo.scm") — a single source of truth for what's
;; actually benchmarked, so the two never drift apart.
(import (scheme base) (scheme write) (scheme inexact) (scheme time)
        (only (racket base) make-hash hash-set! hash-ref))
(include "../../bench/workloads.scm")

;; hashtable-test against Racket's own real, mutable hash (make-hash --
;; equal?-based, so string keys work as expected) -- see creme.scm's own
;; comment (competition/scheme/bench/creme.scm) for the full mixed
;; read/write/growth design and why this workload is defined per-runtime
;; rather than shared in workloads.scm.
(define (hashtable-test n)
  (define h (make-hash))
  (let loop ((i 0))
    (if (< i n)
        (begin (hash-set! h (string-append "k" (number->string i)) (* i 2))
               (loop (+ i 1)))))
  (let loop ((i 0) (acc 0))
    (if (= i n)
        acc
        (case (modulo i 4)
          ((0) (hash-set! h (string-append "k" (number->string (+ n i))) i)
               (loop (+ i 1) acc))
          ((1) (let ((key (string-append "k" (number->string (modulo i n)))))
                 (hash-set! h key (+ (hash-ref h key) 1))
                 (loop (+ i 1) acc)))
          (else (loop (+ i 1) (+ acc (hash-ref h (string-append "k" (number->string (modulo i n)))))))))))

(include "../../bench/workloads-demo.scm")
