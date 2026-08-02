;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/modules/creme/bytecode_spec.cr's
;; own cases exercising (creme bytecode) directly -- see modules/creme/
;; spec.sld's own header comment for the framework this uses. These are
;; asserted against literal expected values (should-equal?), not should-
;; match-native?, since they're testing (creme bytecode)'s own chunk-
;; assembler API directly (op-ordinal, chunk-emit!/chunk-add-const!/
;; chunk-patch-jump-to-here!/chunk-add-upval!/chunk-add-proto!, then
;; load-chunk-bytes), not comparing two compilers' output -- same
;; rationale bootstrap_spec.scm's own header comment gives for the same
;; choice.
;;
;; (creme bytecode) is a pure-Scheme, file-based library (modules/creme/
;; bytecode.sld) -- no native-only surface here, so unlike prim_call_spec.
;; scm (which exercises a NATIVE-only compiler optimization) this passes
;; identically under all three backends, including icecreme/icecreme (whose own
;; self-hosted loader reads this library's source the same way it already
;; does for (creme compiler compiler) etc.).
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/bytecode_spec.scm
;;   ./bin/creme --self-hosted spec/creme/bytecode_spec.scm
;;   ./icecreme/icecreme spec/creme/bytecode_spec.scm
;; ===========================================================================

(import (scheme base) (scheme write) (scheme process-context)
        (creme bytecode) (creme bootstrap) (creme spec))

(define (write-to-string v)
  (let ((port (open-output-string)))
    (write v port)
    (get-output-string port)))

(describe "bytecode module"
  (it "looks up every opcode's ordinal, in Op enum declaration order"
    (should-equal? (op-ordinal 'LoadK) 0)
    (should-equal? (op-ordinal 'SetGlobal) 9)
    (should-equal? (op-ordinal 'Call) 87)
    (should-equal? (op-ordinal 'Closure) 107)
    (should-equal? (op-ordinal 'HelperFormLocal) 118))

  (it "raises clearly on an unknown opcode name"
    (should-raise? (lambda () (op-ordinal 'NotARealOp))))

  ;; (lambda () (if #f 1 2)) inlined as a top-level chunk: load a boolean
  ;; const, test it, jump over the "then" branch.
  (it "builds, patches, and serializes a chunk that runs correctly via load-chunk-bytes"
    (let* ((ch (make-chunk "test"))
           (test-reg 0)
           (dest 1))
      (chunk-num-registers-set! ch 2)
      (chunk-emit! ch 'LoadK test-reg (chunk-add-const! ch #f) 0 0)
      (let ((jmp-false (chunk-emit! ch 'TestFalse test-reg 0 0 0)))
        (chunk-emit! ch 'LoadK dest (chunk-add-const! ch 111) 0 0)
        (let ((jmp-end (chunk-emit! ch 'Jmp 0 0 0 0)))
          (chunk-patch-jump-to-here! ch jmp-false)
          (chunk-emit! ch 'LoadK dest (chunk-add-const! ch 222) 0 0)
          (chunk-patch-jump-to-here! ch jmp-end)
          (chunk-emit! ch 'Return dest 0 0 0)
          (should-equal? (write-to-string (load-chunk-bytes (chunk->bytes ch))) "222")))))

  ;; Hand-builds the equivalent of:
  ;;   (define (make-adder n) (lambda (x) (+ x n)))
  ;;   ((make-adder 5) 10)
  ;; across three chunks (program -> make-adder -> the returned lambda), to
  ;; exercise Closure/GetUpval/proto/upvalue bookkeeping directly through
  ;; this library's own API rather than via the compiler.
  (it "round-trips a chunk with a closure, upvalue capture, and a proto"
    (let ((inner (make-chunk "adder"))
          (outer (make-chunk "make-adder"))
          (program (make-chunk "program")))
      (chunk-param-count-set! inner 1)
      (chunk-num-registers-set! inner 4)
      (let ((n-up (chunk-add-upval! inner 'n #t 0)))
        (chunk-emit! inner 'GetGlobal 1 (chunk-add-const! inner '+) 0 0)
        (chunk-emit! inner 'Move 2 0 0 0)
        (chunk-emit! inner 'GetUpval 3 n-up 0 0)
        (chunk-emit! inner 'TailCall 1 2 0 0))

      (chunk-param-count-set! outer 1)
      (chunk-num-registers-set! outer 2)
      (let ((inner-proto-idx (chunk-add-proto! outer inner)))
        (chunk-emit! outer 'Closure 1 inner-proto-idx 0 0)
        (chunk-emit! outer 'Return 1 0 0 0))

      (chunk-num-registers-set! program 7)
      (let ((outer-proto-idx (chunk-add-proto! program outer)))
        (chunk-emit! program 'Closure 0 outer-proto-idx 0 0)
        (chunk-emit! program 'DefGlobal (chunk-add-const! program 'make-adder) 0 0 0)
        (chunk-emit! program 'GetGlobal 1 (chunk-add-const! program 'make-adder) 0 0)
        (chunk-emit! program 'LoadK 2 (chunk-add-const! program 5) 0 0)
        (chunk-emit! program 'Call 1 1 3 0)
        (chunk-emit! program 'Move 4 3 0 0)
        (chunk-emit! program 'LoadK 5 (chunk-add-const! program 10) 0 0)
        (chunk-emit! program 'Call 4 1 6 0)
        (chunk-emit! program 'Return 6 0 0 0))

      (should-equal? (write-to-string (load-chunk-bytes (chunk->bytes program))) "15"))))

(spec-summary!)
