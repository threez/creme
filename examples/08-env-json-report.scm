(import (scheme base) (scheme write) (creme env) (creme json) (creme regex))

(define (filter-list pred lst)
  (cond ((null? lst) '())
        ((pred (car lst)) (cons (car lst) (filter-list pred (cdr lst))))
        (else (filter-list pred (cdr lst)))))

(define interesting-re (regexp "^PATH$|^HOME$|^USER$|^SHELL$"))

(define interesting
  (filter-list (lambda (entry) (regexp-matches? interesting-re (car entry))) (get-environment-variables)))

(display "Found ") (display (length interesting)) (display " interesting variable(s)") (newline)
(display (json-write interesting)) (newline)
