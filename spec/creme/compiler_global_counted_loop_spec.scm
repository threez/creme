;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/compile/for_loop_opcode_spec.cr's
;; "self-recursive global counted-loop fusion" cases -- see that file's own
;; header comment and bytecode_compiler.cr's try_compile_global_counted_loop
;; for the full rationale: an ordinary self-recursive `(define (f params...)
;; body)` (NOT a let-loop/do) gets the same Op::ForPrep/Op::ForLoopGuardedInc/
;; Dec fusion a let-loop/do already would, since f's own name resolves as a
;; mutable GLOBAL -- Op::TestGlobalIdentity re-checks (by pointer identity)
;; every iteration that the global is still bound to the exact closure
;; that's executing, deopting to a real, unfused recompile of the original
;; `if` the instant a mid-loop redefinition changes that.
;;
;; should-match-native? compiles each source with the SELF-HOSTED compiler
;; and checks it against plain native evaluation of the same source (see
;; modules/creme/compiler/spec-helper.sld) -- both sides now carry this
;; optimization (compiler.sld mirrors bytecode_compiler.cr byte-for-byte),
;; so agreement here is primarily a self-hosted/native PARITY check; the
;; redefinition cases are also cross-checked against the disabled-
;; optimization baseline directly (see spec/scheme/compile/
;; for_loop_opcode_spec.cr's own equivalent cases, and this session's
;; interactive verification) to confirm the deopt path itself is correct,
;; not just that the two compilers agree with each other.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/compiler_global_counted_loop_spec.scm
;;   ./bin/creme --self-hosted spec/creme/compiler_global_counted_loop_spec.scm
;;   ./icecreme/icecreme spec/creme/compiler_global_counted_loop_spec.scm
;; ===========================================================================

(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(describe "self-recursive global counted-loop fusion"

  (it "fuses a plain tail-recursive accumulator define (decrementing counter)"
    (should-match-native?
      '((define (sum-to n acc) (if (= n 0) acc (sum-to (- n 1) (+ acc n))))
        (sum-to 100000 0))))

  (it "fuses an incrementing counted self-recursive define (a global, not a param, bound)"
    ;; The bound must be genuinely loop-invariant, not one of the loop's OWN
    ;; params (detect_counted_loop_shape's hard requirement) -- a global
    ;; constant, unlike a 3rd parameter, can't vary per-call, so it qualifies.
    (should-match-native?
      '((define LIMIT 100000)
        (define (count-up i acc) (if (= i LIMIT) acc (count-up (+ i 1) (+ acc i))))
        (count-up 0 0))))

  (it "still matches native for a step other than +-1 (falls back to plain TailCallGlobal, unfused)"
    (should-match-native?
      '((define (sum-by-2 n acc) (if (= n 0) acc (sum-by-2 (- n 2) (+ acc n))))
        (sum-by-2 100000 0))))

  (it "still matches native for an internal (non-global) self-recursive define"
    (should-match-native?
      '((define (outer)
          (define (sum-to n acc) (if (= n 0) acc (sum-to (- n 1) (+ acc n))))
          (sum-to 100000 0))
        (outer))))

  (it "produces the same result whether or not the global is redefined mid-loop, deopting correctly"
    ;; Redefines `sum-to` itself partway through a long loop (at n ==
    ;; 5,000,000, well after the fast guarded loop would have started) to a
    ;; totally different function -- the fused loop must detect this every
    ;; iteration and hand off to the NEW binding for the remainder, exactly
    ;; like the unoptimized TailCallGlobal path always would.
    (should-match-native?
      '((define (sum-to n acc)
          (if (= n 5000000)
              (begin (set! sum-to (lambda (n acc) (+ 999999 n acc))) (sum-to (- n 1) (+ acc n)))
              (if (= n 0) acc (sum-to (- n 1) (+ acc n)))))
        (sum-to 10000000 0))))

  (it "produces the same result when redefined to another counted-loop-shaped function"
    ;; A subtler redefinition than "swap in something unrelated": the new
    ;; binding is ITSELF a fusable counted loop. The deopt must still hand
    ;; off correctly (the NEW closure's own compiled body -- its own fresh
    ;; guarded loop -- takes over) rather than silently continuing to
    ;; iterate against the OLD closure.
    (should-match-native?
      '((define (sum-to n acc)
          (if (= n 999900)
              (begin
                (set! sum-to (lambda (n acc) (if (= n 0) (+ acc 1000000) (sum-to (- n 1) (+ acc n)))))
                (sum-to (- n 1) (+ acc n)))
              (if (= n 0) acc (sum-to (- n 1) (+ acc n)))))
        (sum-to 1000000 0)))))

(spec-summary!)
