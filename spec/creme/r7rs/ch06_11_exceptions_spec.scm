;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/r7rs/ch06_11_exceptions_spec.cr's
;; own cases -- see modules/creme/spec.sld's own header comment for the
;; framework this uses (which itself already leans on guard/error-object?
;; internally -- see spec.sld's own spec-condition-message -- so these
;; forms are directly exercised as ordinary Scheme here, no sub-
;; interpreter indirection needed the way the original Crystal spec's
;; run(src)/w(src) helpers required).
;;
;; This file used to document four icecreme-only gaps here, each gated behind
;; `it-unless`: plain `raise` not consulting an installed with-exception-
;; handler at all (it used to drive ONLY the C-level guard/GuardHandler
;; longjmp stack); error-object-message returning irritants concatenated
;; in; read-error?/file-error? being unbound. All four are now fixed --
;; with-exception-handler/raise/raise-continuable are genuine icecreme-native
;; builtins (icecreme/builtins.c, backed by a real VM-wide handler stack, see
;; icecreme/vm.h's own UNWIND_EXC_HANDLER doc comment), not just a Scheme-
;; level shim that only worked under icecreme's own "compiler mode" -- so
;; every case in this file runs unconditionally now.
;;
;; Run with (all cases pass, 0 pending, under all three):
;;   ./bin/creme spec/creme/r7rs/ch06_11_exceptions_spec.scm
;;   ./bin/creme --self-hosted spec/creme/r7rs/ch06_11_exceptions_spec.scm
;;   ./icecreme/icecreme spec/creme/r7rs/ch06_11_exceptions_spec.scm
;; ===========================================================================

(import (scheme base) (creme spec))

(describe "R7RS §6.11 Exceptions"
  (it "with-exception-handler installs handler as the current exception handler for thunk's invocation"
    (should-equal?
      (call-with-current-continuation
        (lambda (k)
          (with-exception-handler
            (lambda (x) (k (list "condition:" x)))
            (lambda ()
              (+ 1 (raise 'an-error))))))
      (list "condition:" 'an-error)))

  (it "raise-continuable invokes the handler, whose return value flows back as raise-continuable's result"
    (should-equal?
      (with-exception-handler
        (lambda (con) 42)
        (lambda ()
          (+ (raise-continuable "should be a number") 23)))
      65))

  (it "raise invokes the current exception handler on obj, using a non-continuable exception"
    (should-equal?
      (call/cc (lambda (k)
        (with-exception-handler
          (lambda (e) (k (string-append "caught: " e)))
          (lambda () (raise "boom")))))
      "caught: boom"))

  (it "guard evaluates cond-style clauses against the raised object"
    (should-equal?
      (guard (condition ((assq 'a condition) (cdr (assq 'a condition)))
                         ((assq 'b condition)))
        (raise (list (cons 'a 42))))
      42))

  (it "a guard clause with only a test (no body) returns the test's own value, per cond semantics"
    (should-equal?
      (guard (condition ((assq 'a condition) (cdr (assq 'a condition)))
                         ((assq 'b condition)))
        (raise (list (cons 'b 23))))
      (cons 'b 23)))

  (it "error raises an exception encapsulating a message and irritants"
    (let ()
      (define (null-list? l)
        (cond ((pair? l) #f)
              ((null? l) #t)
              (else (error "null-list?: argument out of domain" l))))
      (should-equal?
        (guard (e (#t (error-object-message e))) (null-list? 5))
        "null-list?: argument out of domain")))

  (it "error-object-irritants returns the list of irritants passed to error"
    (should-equal?
      (guard (e (#t (error-object-irritants e))) (error "boom" 1 2 3))
      (list 1 2 3)))

  (it "error-object? is #t for objects created by error, #f for arbitrary raised objects"
    (should-equal?
      (guard (e ((error-object? e) 'is-obj) (#t 'is-not-obj)) (error "x"))
      'is-obj)
    (should-equal?
      (guard (e ((error-object? e) 'is-obj) (#t 'is-not-obj)) (raise 'my-symbol))
      'is-not-obj))

  (it "raise/guard work with any object, not just error-object?-satisfying ones"
    (should-equal?
      (guard (e ((symbol? e) e)) (raise 'my-symbol))
      'my-symbol))

  (it "read-error?/file-error? are #f for an arbitrary raised object"
    (should-equal?
      (guard (e ((read-error? e) 'read-err) (#t 'other)) (raise 'my-symbol))
      'other)
    (should-equal?
      (guard (e ((file-error? e) 'file-err) (#t 'other)) (raise 'my-symbol))
      'other))

  (it "guard's cond-style (test => proc) arrow-clause form applies proc to the matched test value"
    (should-equal?
      (guard (e ((assq 'a e) => cdr) (#t 'other)) (raise (list (cons 'a 42))))
      42)))

(spec-summary!)
