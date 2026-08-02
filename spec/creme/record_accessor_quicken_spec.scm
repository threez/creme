;; ===========================================================================
;; Correctness coverage for icecreme's OP_QCALLGLOBAL_RECACC (icecreme/vm.c) -- the
;; same call-site quickening trick prim_call_spec.scm's "deopt on
;; redefinition" cases already cover for +/-/*/vector-ref/etc., applied to
;; define-record-type field accessors instead. A top-level accessor call
;; like (point-x p) always compiles to a plain OP_CALLGLOBAL against a
;; T_RECORD_CALLABLE (see icecreme/vm.c's build_record_bindings) -- never a
;; fused op of its own -- so icecreme rewrites that call site to
;; OP_QCALLGLOBAL_RECACC in place the first time it runs, and must deopt
;; back to OP_CALLGLOBAL the instant the accessor's global is redefined or
;; called on the wrong record type.
;;
;; should-match-native? is still the right tool here even though this is a
;; icecreme-only runtime behavior (see prim_call_spec.scm's own header comment
;; on the same point): it asserts the COMPUTED VALUE matches native, not
;; which opcode path produced it, so this doubles as a genuine native/
;; self-hosted/icecreme consistency check regardless of backend, while only
;; actually exercising the quickened path when run under icecreme.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/record_accessor_quicken_spec.scm
;;   ./bin/creme --self-hosted spec/creme/record_accessor_quicken_spec.scm
;;   ./icecreme/icecreme spec/creme/record_accessor_quicken_spec.scm
;; ===========================================================================

(import (scheme base) (scheme cxr) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(describe "record accessor call-site quickening (OP_QCALLGLOBAL_RECACC)"
  (it "computes correctly across many repeated calls (forces icecreme's runtime quicken to engage)"
    (should-match-native?
      '((define-record-type point (make-point x y) point? (x point-x) (y point-y))
        (define p (make-point 3 4))
        (define (sum-loop n acc)
          (if (= n 0) acc (sum-loop (- n 1) (+ acc (point-x p) (point-y p)))))
        (sum-loop 50 0))))

  (it "still raises when the accessor is called on a value from a different record type"
    (should-raise?
      (lambda ()
        (bootstrap-eval-forms
          '((define-record-type box (make-box v) box? (v box-v))
            (define b (make-box 1))
            (point-x b))))))

  (it "deopts to a runtime redefinition of the accessor, and re-quickens once restored"
    (should-match-native?
      '((define real-point-x point-x)
        (set! point-x (lambda (pt) 'shadowed))
        (define shadowed-result (point-x p))
        (set! point-x real-point-x)
        (define (sum-loop2 n acc)
          (if (= n 0) acc (sum-loop2 (- n 1) (+ acc (point-x p) (point-y p)))))
        (list shadowed-result (sum-loop2 50 0) (point-x p))))))

(spec-summary!)
