(require 'regex)

(define email-re (regex:compile "^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$"))

(define candidates
  (list "ada@lovelace.dev" "not-an-email" "grace@hopper" "alan.turing@bletchley.uk" "@missing-local.com"))

(define (partition pred lst)
  (list (filter pred lst) (filter (lambda (x) (not (pred x))) lst)))

(define result (partition (lambda (s) (regex:match? email-re s)) candidates))

(println "Valid:   " (first result))
(println "Invalid: " (second result))
