;; ===========================================================================
;; Correctness coverage for cvm's OP_QCALLGLOBAL_ADD3/MOD2 (cvm/vm.c) --
;; two more call-site quickening cases in the same family as
;; OP_QCALLGLOBAL_ADD2/etc. and OP_QCALLGLOBAL_RECACC (see
;; record_accessor_quicken_spec.scm's own header comment for the general
;; mechanism this all shares).
;;
;; A 3-argument call to `+` (e.g. `(+ acc x y)`, found live in
;; competition/bench/workloads.scm's own record-test) never gets the
;; native/self-hosted compiler's own static 2-operand arithmetic fusion
;; (see doc/optimization-cvm.md Section 3) -- it always compiles to a
;; plain OP_CALLGLOBAL regardless of redefinition tracking, exactly the
;; same "only quickening ever reaches this call site" situation the 2-arg
;; opcodes already handle. `modulo` isn't in the compiler's static fusion
;; list at any arity, so it always compiles to OP_CALLGLOBAL too.
;;
;; should-match-native? is still the right tool here even though this is
;; a cvm-only runtime behavior (see prim_call_spec.scm's own header
;; comment on the same point): it asserts the COMPUTED VALUE matches
;; native, not which opcode path produced it, so it doubles as a genuine
;; native/self-hosted/cvm consistency check regardless of backend, while
;; only actually exercising the quickened path when run under cvm.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/prim_quicken_spec.scm
;;   ./bin/creme --self-hosted spec/creme/prim_quicken_spec.scm
;;   ./cvm/cvm spec/creme/prim_quicken_spec.scm
;; ===========================================================================

(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(describe "3-arg + call-site quickening (OP_QCALLGLOBAL_ADD3)"
  (it "computes correctly across many repeated calls (forces cvm's runtime quicken to engage)"
    (should-match-native?
      '((define (sum3-loop n acc) (if (= n 0) acc (sum3-loop (- n 1) (+ acc n (* n 2)))))
        (sum3-loop 50 0)))))

(describe "modulo call-site quickening (OP_QCALLGLOBAL_MOD2)"
  (it "computes correctly across many repeated calls, including negative operands"
    (should-match-native?
      '((define (mod-loop n acc) (if (= n 0) acc (mod-loop (- n 1) (+ acc (modulo n 7) (modulo (- n) 7)))))
        (mod-loop 50 0))))

  (it "still raises on a zero divisor, both before and after the call site has quickened"
    (should-raise? (lambda () (bootstrap-eval-forms '((modulo 5 0)))))
    (should-raise?
      (lambda ()
        (bootstrap-eval-forms
          '((define (mod-loop n acc) (if (= n 0) acc (mod-loop (- n 1) (+ acc (modulo n 7)))))
            (mod-loop 50 0)
            (modulo 1 0)))))))

;; ---------------------------------------------------------------------------
;; Deopt-on-redefinition cases -- moved to the end, same reason
;; prim_call_spec.scm's own equivalent block is (see that file's header
;; comment): once `+`/`modulo` are shadowed here, every later
;; should-match-native? call in this file would see the shadowed meaning.
;; ---------------------------------------------------------------------------
(describe "deopt on redefinition (moved to the end -- see header comment)"
  (it "deopts a quickened 3-arg + call site to a runtime redefinition, and re-quickens once restored"
    (should-match-native?
      '((define (sum3 x y z) (+ x y z))
        (define (loop3 n) (if (= n 0) 'done (begin (sum3 1 2 3) (loop3 (- n 1)))))
        (loop3 50)
        (define real+ +)
        (set! + (lambda (a b c) (list 'shadowed a b c)))
        (define shadowed-result (sum3 1 2 3))
        (set! + real+)
        (list shadowed-result (sum3 1 2 3) (loop3 50)))))

  ;; A literal should-equal? on bootstrap-eval-forms directly, not
  ;; should-match-native? -- same reason compiler_defmacro_spec.scm's own
  ;; two redefinition cases do (see that file's header comment):
  ;; should-match-native? also runs native-eval-forms, which re-invokes
  ;; eval/compile per form; `modulo` is used internally by (creme
  ;; bytecode)'s own int->le-bytes (see builtins.c's bi_modulo doc
  ;; comment), so compiling a LATER form while an EARLIER form in this
  ;; same sequence has `modulo` shadowed can corrupt that later form's own
  ;; compiled constants. bootstrap-eval-forms alone compiles this whole
  ;; sequence in one pass, before any of it runs, sidestepping that.
  (it "deopts a quickened modulo call site to a runtime redefinition, and re-quickens once restored"
    (should-equal?
      (write-to-string
        (bootstrap-eval-forms
          '((define (mod-sum n acc) (if (= n 0) acc (mod-sum (- n 1) (+ acc (modulo n 7)))))
            (mod-sum 50 0)
            (define real-modulo modulo)
            (set! modulo (lambda (a b) 'shadowed))
            (define shadowed-result (modulo 10 3))
            (set! modulo real-modulo)
            (list shadowed-result (mod-sum 50 0) (modulo 10 3)))))
      "(shadowed 148 1)")))

(spec-summary!)
