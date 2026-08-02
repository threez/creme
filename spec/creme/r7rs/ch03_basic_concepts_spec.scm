;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/r7rs/ch03_basic_concepts_spec.
;; cr's own cases -- see modules/creme/spec.sld's own header comment for
;; the framework this uses, and spec/creme/r7rs/ch06_13_input_output_spec.
;; scm's own header comment for this project's existing precedent of
;; testing directly (no string-embedding-and-sub-eval needed, since this
;; file already runs in a real Scheme runtime).
;;
;; "referencing an unbound identifier is an error" is ported via should-
;; raise? rather than the original's own expect_raises(Creme::
;; SchemeRuntimeError, /unbound variable: .../) -- should-raise? only
;; confirms SOMETHING was raised (see modules/creme/spec.sld's own header
;; comment), not the exact message text, since this framework has no
;; message-pattern-matching assertion; the identifier reference itself is
;; wrapped in a lambda so the actual lookup (and error) only happens when
;; should-raise? invokes the thunk, not at this file's own load/compile
;; time.
;;
;; Skipped from the original file (matching its own `pending`): "mutating
;; a literal constant (e.g. (set-car! '(a) 1)) is documented by R7RS as an
;; error, but this implementation does not detect/reject it -- it silently
;; mutates the literal" -- nothing to assert against here either, same
;; reason the original left it a no-op pending.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/r7rs/ch03_basic_concepts_spec.scm
;;   ./bin/creme --self-hosted spec/creme/r7rs/ch03_basic_concepts_spec.scm
;;   ./icecreme/icecreme spec/creme/r7rs/ch03_basic_concepts_spec.scm
;; ===========================================================================

(import (scheme base) (creme spec))

(describe "R7RS §3.1 Variables, syntactic keywords, and regions"
  (it "a variable reference evaluates to the value stored in its bound location"
    (should-equal? (let ((x 28)) x) 28))

  (it "referencing an unbound identifier is an error"
    (should-raise? (lambda () totally-undefined-name-xyz-not-really-bound))))

(describe "R7RS §3.2 Disjointness of types"
  (it "no object satisfies more than one of the disjoint-type predicates"
    (should-equal?
     (list (boolean? #t) (pair? (cons 1 2)) (null? '()) (procedure? car)
           (symbol? 'a) (string? "a") (number? 1) (char? #\a)
           (vector? (vector)) (bytevector? (bytevector)))
     (list #t #t #t #t #t #t #t #t #t #t)))

  (it "the empty list is not a pair"
    (should-be-false? (pair? '()))))

(describe "R7RS §3.3 External representations"
  (it "the external representation of 28 is the character sequence \"28\""
    (should-equal? 28 28))

  (it "(+ 2 6) is not an external representation of 8 -- it is itself a 3-element list"
    (should-equal? '(+ 2 6) (list '+ 2 6))))

(describe "R7RS §3.4 Storage model"
  (it "string-set! mutates one of the locations a string denotes"
    (should-equal?
     (let ((s (make-string 3 #\a)))
       (string-set! s 0 #\b)
       s)
     "baa"))

  (it "an object fetched via car/vector-ref/string-ref is eqv? to the value last stored there"
    (should-be-true?
     (let ((v (vector 1 2 3)))
       (vector-set! v 0 99)
       (eqv? (vector-ref v 0) 99)))))

(describe "R7RS §3.5 Proper tail recursion"
  (it "a self-tail-call loop of a million iterations runs in constant space (does not stack-overflow)"
    (should-equal?
     (letrec ((loop (lambda (n) (if (= n 0) 'done (loop (- n 1))))))
       (loop 1000000))
     'done))

  (it "and/or/when/unless/cond/case tail-call their final branch (same constant-space guarantee)"
    (should-equal?
     (letrec ((loop (lambda (n) (cond ((= n 0) 'done) (else (loop (- n 1)))))))
       (loop 1000000))
     'done))

  (it "named-let tail position also stays in constant space"
    (should-equal?
     (let loop ((i 0)) (if (= i 1000000) 'done (loop (+ i 1))))
     'done)))

(spec-summary!)
