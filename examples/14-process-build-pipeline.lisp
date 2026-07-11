(require 'process)
(require 'time)

(define steps
  (list (list "check environment" "sh" (list "-c" "command -v echo > /dev/null"))
        (list "run build"         "sh" (list "-c" "echo Building... && echo Build OK"))
        (list "run tests"         "sh" (list "-c" "echo Running tests... && exit 0"))))

(define (run-step step)
  (let* ((name (first step))
         (cmd  (second step))
         (args (third step))
         (start (time:now))
         (result (process:run cmd args))
         (elapsed (time:diff (time:now) start))
         (ok (cadddr result)))
    (println name ": " (if ok "PASS" "FAIL") " (" elapsed "s, exit " (caddr result) ")")
    ok))

(define all-ok (reduce (lambda (acc step) (and acc (run-step step))) #t steps))
(println (if all-ok "Pipeline succeeded" "Pipeline failed"))
