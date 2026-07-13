(import (scheme base) (scheme write) (creme regex))

(define (filter-list pred lst)
  (cond ((null? lst) '())
        ((pred (car lst)) (cons (car lst) (filter-list pred (cdr lst))))
        (else (filter-list pred (cdr lst)))))

(define email-re (regexp "^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$"))

(define candidates
  (list "ada@lovelace.dev" "not-an-email" "grace@hopper" "alan.turing@bletchley.uk" "@missing-local.com"))

(define (split-valid pred lst)
  (list (filter-list pred lst) (filter-list (lambda (x) (not (pred x))) lst)))

(define result (split-valid (lambda (s) (regexp-matches? email-re s)) candidates))

(display "Valid:   ") (display (car result)) (newline)
(display "Invalid: ") (display (cadr result)) (newline)
