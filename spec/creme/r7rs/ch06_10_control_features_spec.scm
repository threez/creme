;; ===========================================================================
;; A (creme spec)-based port of
;; spec/scheme/r7rs/ch06_10_control_features_spec.cr's own cases -- see
;; modules/creme/spec.sld's own header comment for the framework this
;; uses. The original Crystal spec evaluated each case's Scheme source via
;; a fresh sub-interpreter (run(src)/w(src)) since it was testing a Scheme
;; interpreter from OUTSIDE, as Crystal code; here, running directly as
;; Scheme, each case's forms are written and asserted directly via
;; should-equal?/should-be-true?/should-be-false? instead.
;;
;; Omitted (as the original file's own `pending` already flagged): a case
;; re-invoking a captured continuation AFTER its own call/cc has already
;; returned (`(define k #f) (+ 1 (call/cc (lambda (c) (set! k c) 1)))`
;; then later `(k 2)`), which would need full R7RS multi-shot/re-entrant
;; continuations to resume and yield 3. This project's call/cc is
;; ESCAPE-ONLY everywhere (native VM AND icecreme/icecreme -- see icecreme/README.md's
;; "call/cc"/"dynamic-wind" section and value.h's own `Continuation` doc
;; comment): a continuation invoked outside the dynamic extent of its own
;; call/cc raises instead of resuming, so this case cannot be ported
;; faithfully under any of the three runtimes and is left out rather than
;; asserted against a value it can never actually produce. Every other
;; call/cc/dynamic-wind case below only relies on escape/early-return
;; semantics (packaging the current continuation as an escape procedure,
;; unwinding through a for-each loop or list recursion, or escaping past
;; an enclosing dynamic-wind), which this project's call/cc genuinely
;; supports -- same precedent as spec/creme/vm_spec.scm's own "dynamic-
;; wind, call/cc, with-exception-handler" section.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/r7rs/ch06_10_control_features_spec.scm
;;   ./bin/creme --self-hosted spec/creme/r7rs/ch06_10_control_features_spec.scm
;;   ./icecreme/icecreme spec/creme/r7rs/ch06_10_control_features_spec.scm
;; ===========================================================================

(import (scheme base) (scheme inexact) (creme spec))

(describe "R7RS §6.10 Control features"
  (it "procedure? is #t for procedures, #f otherwise"
    (should-be-true? (procedure? car))
    (should-be-false? (procedure? 'car))
    (should-be-true? (procedure? (lambda (x) (* x x)))))

  (it "apply calls proc with the elements of the argument lists appended together"
    (should-equal? (apply + (list 3 4)) 7)
    (should-equal?
      (let ()
        (define (compose f g) (lambda args (f (apply g args))))
        ((compose sqrt *) 12 75))
      30))

  (it "map applies proc element-wise to one or more lists, terminating on the shortest"
    (should-equal? (map cadr (list (list 'a 'b) (list 'd 'e) (list 'g 'h))) (list 'b 'e 'h))
    (should-equal? (map (lambda (n) (expt n n)) (list 1 2 3 4 5)) (list 1 4 27 256 3125))
    (should-equal? (map + (list 1 2 3) (list 4 5 6)) (list 5 7 9)))

  (it "for-each is like map but calls proc for side effects, guaranteed left-to-right"
    (let ((v (make-vector 5)))
      (for-each (lambda (i) (vector-set! v i (* i i))) (list 0 1 2 3 4))
      (should-equal? v (vector 0 1 4 9 16))))

  (it "call-with-current-continuation packages the current continuation as an escape procedure"
    (should-equal?
      (call-with-current-continuation
        (lambda (exit)
          (for-each (lambda (x) (if (negative? x) (exit x))) (list 54 0 37 -3 245 19))
          #t))
      -3))

  (it "call/cc is a synonym for call-with-current-continuation"
    (should-equal?
      (let ()
        (define (list-length obj)
          (call/cc
            (lambda (return)
              (letrec ((r (lambda (obj)
                            (cond ((null? obj) 0)
                                  ((pair? obj) (+ (r (cdr obj)) 1))
                                  (else (return #f))))))
                (r obj)))))
        (list (list-length (list 1 2 3 4)) (list-length (cons 'a (cons 'b 'c)))))
      (list 4 #f)))

  (it "values delivers all of its arguments to its continuation"
    (should-equal? (call-with-values (lambda () (values 4 5)) (lambda (a b) b)) 5))

  (it "call-with-values calls producer with no arguments, then applies consumer to the resulting values"
    (should-equal? (call-with-values (lambda () (values 4 5)) +) 9)
    (should-equal? (call-with-values * -) -1))

  (it "dynamic-wind calls thunk, guaranteeing before/after run exactly once each around normal return"
    (should-equal?
      (let ((log '()))
        (dynamic-wind
          (lambda () (set! log (cons 'enter log)))
          (lambda () 'body-result)
          (lambda () (set! log (cons 'exit log))))
        (reverse log))
      (list 'enter 'exit)))

  (it "dynamic-wind's before/after also run around a call/cc escape past the dynamic-wind call"
    (should-equal?
      (let ((log '()))
        (define (record! s) (set! log (cons s log)))
        (call/cc (lambda (k)
          (dynamic-wind
            (lambda () (record! 'enter))
            (lambda () (k (begin (record! 'done) 'done)))
            (lambda () (record! 'exit)))))
        (reverse log))
      (list 'enter 'done 'exit))))

(spec-summary!)
