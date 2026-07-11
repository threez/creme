(require 'file)

(define module-path "/tmp/crisp-example-greeter.lisp")

(file:write module-path
  "(define (greet name) (string-append \"Hello, \" name \"!\"))\n(define (shout-all names) (map greet names))")

(require "/tmp/crisp-example-greeter.lisp")

(println (crisp-example-greeter:greet "Ada"))
(println (crisp-example-greeter:shout-all '("Grace" "Alan")))

(file:delete module-path)
