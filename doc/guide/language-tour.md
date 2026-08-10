# Language tour

A quick tour of the language by example. For the full standard-library surface see
[Libraries](libraries.md); for the deliberately-out-of-scope edge cases see the
**Known caveats** section of the [README](../../README.md#known-caveats).

```scheme
(define (fact n) (if (<= n 1) 1 (* n (fact (- n 1)))))
(fact 10) ; => 3628800

; closures
(define (make-counter)
  (let ((n 0))
    (lambda () (set! n (+ n 1)) n)))
(define c (make-counter))
(list (c) (c) (c)) ; => (1 2 3)

; higher-order functions
(map (lambda (x) (* x x)) '(1 2 3 4))     ; => (1 4 9 16)
(filter (lambda (x) (> x 2)) '(1 2 3 4))  ; => (3 4)
(reduce + 0 '(1 2 3 4 5))                 ; => 15

; cond / else
(define (sign x)
  (cond ((> x 0) 'positive) ((< x 0) 'negative) (else 'zero)))

; quasiquote
`(1 ,(+ 1 1) ,@(list 3 4)) ; => (1 2 3 4)

; case
(define (day-kind d) (case d ((sat sun) 'weekend) (else 'weekday)))

; named let / do — two ways to iterate
(let loop ((i 0) (acc 0)) (if (= i 5) acc (loop (+ i 1) (+ acc i)))) ; => 10
(do ((i 0 (+ i 1)) (acc 0 (+ acc i))) ((= i 5) acc))                 ; => 10

; define-record-type
(define-record-type point (make-point x y) point? (x point-x) (y point-y))
(point-x (make-point 3 4)) ; => 3

; guard / error-object-message
(guard (e (#t (list 'caught (error-object-message e)))) (error "boom"))

; exact rationals: division of exact numbers stays exact
(/ 1 3)                    ; => 1/3 (not 0.333...)
(+ (/ 1 3) (/ 1 6))         ; => 1/2
(exact->inexact (/ 1 3))   ; => 0.3333333333333333

; values / call-with-values
(call-with-values (lambda () (values 1 2 3)) +) ; => 6

; call/cc: non-local exit (escape continuations only, see Known caveats)
(call/cc (lambda (return)
  (for-each (lambda (x) (if (> x 3) (return x))) '(1 2 3 4 5))
  'not-found)) ; => 4

; raise / with-exception-handler / raise-continuable
(with-exception-handler
  (lambda (e) 42)                       ; the handler's return value...
  (lambda () (+ 1 (raise-continuable 'oops)))) ; ...flows back in-line: => 43

; dynamic-wind: before/after always run in pairs, even across a call/cc escape
(call/cc (lambda (k)
  (dynamic-wind
    (lambda () (display "enter ") )
    (lambda () (k 'done))
    (lambda () (display "exit ")))))     ; prints "enter exit "

; bytevectors
(define bv (bytevector 72 105))
(utf8->string bv)                        ; => "Hi"
#u8(1 2 3)                               ; reader literal syntax

; complex numbers
(import (scheme complex))
3+4i                                     ; reader literal syntax
(magnitude 3+4i)                         ; => 5.0
(sqrt -4)                                ; => 0.0+2.0i
```

Booleans are `#t`/`#f`, the empty list/nil is `()`, predicates end in `?`
(`even?`, `null?`), mutators end in `!` (`set!`, `set-car!`). There's no
`defun`/`loop`/`dotimes` — use the `(define (name args...) body)` sugar, `do` or
named-`let` for iteration, and `map`/`filter`/`for-each`/`foldl`/`foldr`/`reduce`,
or recursion.

See `examples/` for complete, runnable programs (numbered by topic), and
`examples/demo.scm` for a quick tour of the core language.
