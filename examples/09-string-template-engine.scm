(import (scheme base) (scheme write) (creme string))

(define (reduce-list f init lst)
  (if (null? lst) init (reduce-list f (f init (car lst)) (cdr lst))))

(define (render template bindings)
  (reduce-list
    (lambda (text binding)
      (string-replace text (string-append "{{" (car binding) "}}") (cdr binding)))
    template
    bindings))

(define bindings
  (list (cons "name" "Ada")
        (cons "product" "scheme.cr")
        (cons "count" "20")))

(define template
  "Hello {{name}}, thanks for trying {{product}}! You've unlocked {{count}} examples.")

(display (render template bindings)) (newline)
