; R7RS exception handling: raise/raise-continuable/with-exception-handler,
; layered on top of guard. A tiny "pipeline" of stages where a warning is
; continuable (the pipeline keeps going with a substituted value) but a
; fatal error is not (it aborts the whole run, caught by the outer guard).

(import (scheme base) (scheme write) (scheme cxr))

(define (validate-stage n)
  (cond
    ((negative? n) (raise (list 'fatal "negative input" n)))
    ((> n 100) (raise-continuable (list 'warning "clamping to 100" n)))
    (else n)))

(define (run-pipeline values)
  (with-exception-handler
    (lambda (condition)
      (case (car condition)
        ((warning)
         (display "  warning: ") (display (cadr condition))
         (display " (") (display (caddr condition)) (display ")") (newline)
         100) ; raise-continuable's caller gets this value back in-line
        (else (raise condition)))) ; not ours to handle -- pass it on
    (lambda ()
      (map validate-stage values))))

(display "pipeline over normal + over-limit values:") (newline)
(display (run-pipeline '(10 50 150 30))) (newline)
(newline)

(display "pipeline that hits a fatal value, caught by the outer guard:") (newline)
(display
  (guard (e ((and (pair? e) (eq? (car e) 'fatal))
             (list 'aborted (cadr e))))
    (run-pipeline '(10 -5 30))))
(newline)
