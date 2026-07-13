(import (scheme base) (scheme write) (creme json))

(define (filter-list pred lst)
  (cond ((null? lst) '())
        ((pred (car lst)) (cons (car lst) (filter-list pred (cdr lst))))
        (else (filter-list pred (cdr lst)))))

(define people-json "[{\"name\":\"Ada\",\"age\":36,\"active\":true},{\"name\":\"Grace\",\"age\":85,\"active\":false},{\"name\":\"Alan\",\"age\":41,\"active\":true}]")

(define people (vector->list (json-read people-json)))

(define (field person key) (cdr (assoc key person)))
(define (summarize p) (list (cons "name" (field p "name")) (cons "age" (field p "age"))))

(define active-people (filter-list (lambda (p) (field p "active")) people))

(display "All names: ") (display (map (lambda (p) (field p "name")) people)) (newline)
(display "Active count: ") (display (length active-people)) (newline)
(display "Active summary JSON: ") (display (json-write (list->vector (map summarize active-people)))) (newline)
