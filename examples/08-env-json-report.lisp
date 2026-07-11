(require 'env)
(require 'json)
(require 'regex)

(define interesting-re (regex:compile "^PATH$|^HOME$|^USER$|^SHELL$"))

(define interesting
  (filter (lambda (entry) (regex:match? interesting-re (car entry))) (env:all)))

(println "Found " (length interesting) " interesting variable(s)")
(println (json:stringify interesting))
