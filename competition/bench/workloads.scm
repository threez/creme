; Portable R7RS micro-benchmark bodies: pure (scheme base)/(scheme write)/
; (scheme inexact) usage only, so they run unmodified on any conformant R7RS
; implementation (verified against Racket's `#lang r7rs`).
;
; Workloads, chosen to exercise different interpreter hot paths:
;   - fib: deep non-tail recursion (stack/call overhead)
;   - sum-to: tail-recursive accumulation (trampoline/TCO)
;   - list building + reverse + length (allocation, list traversal)
;   - vector fill + sum (mutable array access)
;   - hashtable-test: mixed read/write/growth traffic against each
;     runtime's own NATIVE hash/map/dict -- deliberately NOT defined in
;     this shared file (see the note below on why), unlike every other
;     workload here
;   - record fill + sum (mutable define-record-type field access -- the
;     read side is exactly what icecreme's OP_QCALLGLOBAL_RECACC call-site
;     quickening targets, see doc/optimization-icecreme.md's "Call-site
;     quickening for record accessors" section)
;   - string building via a string output port (growable-buffer writes)
;   - tak: the Gabriel Takeuchi benchmark, triply-nested non-tail recursion
;     over small integers (call dispatch + integer arithmetic, no allocation)
;   - nqueens: backtracking search that conses a growing position list and
;     walks it per candidate (recursion + allocation + list traversal together)
;
; This file has no (import ...) line of its own and is never run directly —
; it's just the workload definitions, spliced in via (include
; "../../bench/workloads.scm") by competition/scheme/bench/creme.scm,
; competition/racket/bench/racket.scm, and (include "workloads.scm", same
; directory) by competition/bench/prof.scm, so the exact same benchmarked
; code runs under all three, with a single source of truth instead of copies
; to keep in sync. creme.scm and racket.scm also (include
; "../../bench/workloads-demo.scm") right after this one, to print each
; workload's own timed result — prof.scm includes only this file, since it
; profiles these same definitions itself and has no use for that printed
; demo run (see workloads-demo.scm's own header comment).
;
; hashtable-test is the one exception to "single shared definition": it's
; deliberately NOT defined here, and each of creme.scm/racket.scm/
; guile.scm/prof.scm defines its own copy instead, immediately before
; including workloads-demo.scm (whose driver loop still just calls
; (hashtable-test n) by name, unmodified). That's because the whole point
; of this workload is to measure each runtime's own NATIVE hash/map/dict
; integration (creme's (creme hash-table), Racket's make-hash, Guile's
; (ice-9 hash-table), and so on across every non-Scheme port too) -- and
; unlike every other workload above, a native hash table has no portable
; R7RS-small API shared across creme/Racket-r7rs/Guile-r7rs to hand-roll
; around, so there is no single body that could live in this shared file.
; This used to be a hand-rolled open-addressing table (identical in every
; language's own bench.* file) specifically so the comparison was "same
; algorithm, different language" rather than "creme's hand-rolled table
; vs. V8's tuned Map" -- deliberate at the time (see git history:
; "hashtable-test: redesign as open addressing across all 8 language
; ports"), but the wrong thing to measure for a suite whose whole point is
; comparing real-world runtime integration: real programs use their
; language's own hash table, not a hand-rolled one, so that's what this
; now measures instead.

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

; A vector of n distinct records, each filled in once then read back through
; its own field accessors -- mirroring vector-sum-test's own write-then-read
; structure (distinct storage per index, so nothing here is loop-invariant
; and foldable away) but storing a record per slot instead of a raw integer,
; so the read loop's cost is genuinely per-accessor-call. This distinct-
; storage-per-index shape matters: an earlier version of this benchmark
; reused ONE mutable record across all n iterations, which a native AOT
; compiler (observed under Crystal --release) could prove never escapes and
; fully constant-fold/hoist away, collapsing what should be a real per-call
; accessor benchmark into a near-zero-cost no-op. The read side here is
; exactly the shape icecreme's OP_QCALLGLOBAL_RECACC call-site quickening
; targets (see doc/optimization-icecreme.md's "Call-site quickening for record
; accessors" section).
(define-record-type bench-point
  (make-bench-point x y) bench-point?
  (x bench-point-x) (y bench-point-y))

(define (record-test n)
  (let ((v (make-vector n)))
    (let loop ((i 0))
      (if (< i n)
          (begin (vector-set! v i (make-bench-point i (* i 2))) (loop (+ i 1)))))
    (let loop ((i 0) (acc 0))
      (if (= i n)
          acc
          (let ((p (vector-ref v i)))
            (loop (+ i 1) (+ acc (bench-point-x p) (bench-point-y p))))))))

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
