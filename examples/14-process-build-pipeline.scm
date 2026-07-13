(import (scheme base) (scheme write) (scheme cxr) (creme process) (creme time))

(define (reduce-list f init lst)
  (if (null? lst) init (reduce-list f (f init (car lst)) (cdr lst))))

(define steps
  (list (list "check environment" "sh" (list "-c" "command -v echo > /dev/null"))
        (list "run build"         "sh" (list "-c" "echo Building... && echo Build OK"))
        (list "run tests"         "sh" (list "-c" "echo Running tests... && exit 0"))))

(define (run-step step)
  (let* ((name (car step))
         (cmd  (cadr step))
         (args (caddr step))
         (start (current-time))
         (result (process-run cmd args))
         (elapsed (time-difference (current-time) start))
         (ok (cadddr result)))
    (display name) (display ": ") (display (if ok "PASS" "FAIL")) (display " (") (display elapsed) (display "s, exit ") (display (caddr result)) (display ")") (newline)
    ok))

(define all-ok (reduce-list (lambda (acc step) (and acc (run-step step))) #t steps))
(display (if all-ok "Pipeline succeeded" "Pipeline failed")) (newline)
