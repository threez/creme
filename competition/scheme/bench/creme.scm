; creme's own entry point for competition/bench/workloads.scm — the
; counterpart to competition/racket/bench/racket.scm, run standalone as its
; own process by competition/bench.scm (which invokes bin/creme the same way
; it invokes bin/bench_cr/ruby/racket, for a uniform 4-variant comparison).
(import (scheme base) (scheme write) (scheme inexact) (scheme time) (creme hash-table))
(include "../../bench/workloads.scm")

; hashtable-test: mixed read/write/growth traffic against creme's own
; REAL (creme hash-table) -- see workloads.scm's own note on why this
; workload is defined per-runtime instead of shared there. Both native
; bin/creme and cvm (cvm/hashtable.c) implement this same API, so this is
; a genuine creme-vs-cvm hash-table comparison too, not just scaffolding
; around a benchmark.
;
; String keys ("k" ++ i), not raw integers, everywhere this workload is
; defined (every other language's own bench.* file does the same) --
; critical for Lua specifically (a table with small sequential integer
; keys stores them in Lua's array part, silently skipping its hash part
; entirely), and it matches how real programs commonly key by string ids
; anyway. This runs identically enough to be checksum-compared across
; every runtime (see competition/bench.scm's own cross-language table).
;
; Phase 1: n inserts into an empty table -- growth from zero.
; Phase 2: n more operations, mixed by i mod 4:
;   0 (25%) - insert a brand-new key -> further growth
;   1 (25%) - read-modify-write an existing key (a real read AND write)
;   else (50%) - pure read of an existing key, accumulated into acc
; So across phase 2: reads happen on 75% of iterations (including inside
; the update case), writes on 50% -- a "mostly-read, some in-place
; writes, occasional growth" mix, not "fill once, read once."
(define (hashtable-test n)
  (define h (make-hash-table))
  (let loop ((i 0))
    (if (< i n)
        (begin (hash-table-set! h (string-append "k" (number->string i)) (* i 2))
               (loop (+ i 1)))))
  (let loop ((i 0) (acc 0))
    (if (= i n)
        acc
        (case (modulo i 4)
          ((0) (hash-table-set! h (string-append "k" (number->string (+ n i))) i)
               (loop (+ i 1) acc))
          ((1) (let ((key (string-append "k" (number->string (modulo i n)))))
                 (hash-table-set! h key (+ (hash-table-ref h key) 1))
                 (loop (+ i 1) acc)))
          (else (loop (+ i 1) (+ acc (hash-table-ref h (string-append "k" (number->string (modulo i n)))))))))))

(include "../../bench/workloads-demo.scm")
