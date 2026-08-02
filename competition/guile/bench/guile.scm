;; GNU Guile counterpart of competition/scheme/bench/creme.scm /
;; competition/racket/bench/racket.scm's own workload run: same imports, same
;; (include "../../bench/workloads.scm")/(include
;; "../../bench/workloads-demo.scm") — one source of truth for what's
;; benchmarked, so no variant drifts from the others. Run standalone as its
;; own process by competition/bench.scm (which invokes `guile` the same way
;; it invokes racket/ruby).
(import (scheme base) (scheme write) (scheme inexact) (scheme time)
        (ice-9 hash-table))
(include "../../bench/workloads.scm")

;; hashtable-test against Guile's own real hash table ((ice-9 hash-table),
;; equal?-based hash-set!/hash-ref) -- see creme.scm's own comment
;; (competition/scheme/bench/creme.scm) for the full mixed read/write/
;; growth design and why this workload is defined per-runtime rather than
;; shared in workloads.scm (Guile's R7RS mode has no (scheme hash-table)
;; of its own to use instead -- verified directly: `guile3 --r7rs` fails
;; to resolve that library at all).
(define (hashtable-test n)
  (define h (make-hash-table))
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
