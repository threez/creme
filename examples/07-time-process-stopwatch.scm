(import (scheme base) (scheme write) (scheme cxr) (creme time) (creme process))

(define (timed-run label cmd args)
  (let* ((start (current-time))
         (result (process-run cmd args))
         (elapsed (time-difference (current-time) start)))
    (display label) (display " -> exit ") (display (caddr result)) (display ", ") (display elapsed) (display "s") (newline)
    result))

(timed-run "list /tmp"     "ls"    (list "/tmp"))
(timed-run "print date"    "date"  (list))
(timed-run "sleep 1s"      "sleep" (list "1"))
