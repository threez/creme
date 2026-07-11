(require 'string)

(define (render template bindings)
  (reduce
    (lambda (text binding)
      (string:replace text (string-append "{{" (car binding) "}}") (cdr binding)))
    template
    bindings))

(define bindings
  (list (cons "name" "Ada")
        (cons "product" "lisp.cr")
        (cons "count" "20")))

(define template
  "Hello {{name}}, thanks for trying {{product}}! You've unlocked {{count}} examples.")

(println (render template bindings))
