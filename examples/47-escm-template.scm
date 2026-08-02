(import (scheme base) (scheme write) (creme escm))

(define greeting-tmpl
  (escm-compile "Hello, <%= name %>! You have <%= count %> new message<% (if (not (= count 1)) (display \"s\")) %>."))

(display (escm-render greeting-tmpl (list (cons 'name "Ada") (cons 'count 1))))
(newline)
(display (escm-render greeting-tmpl (list (cons 'name "Grace") (cons 'count 3))))
(newline)
(newline)

;; A code block can hold several statements, and locals are fresh per render.
(define report-tmpl
  (escm-compile
   (string-append
    "<% (define total (apply + scores)) %>"
    "<% (define avg (/ total (length scores))) %>"
    "scores: <%= scores %>\n"
    "total: <%= total %>, average: <%= avg %>\n")))

(display (escm-render report-tmpl (list (cons 'scores (list 10 20 30)))))
