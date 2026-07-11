(require 'time)
(require 'process)

(define (timed-run label cmd args)
  (let* ((start (time:now))
         (result (process:run cmd args))
         (elapsed (time:diff (time:now) start)))
    (println label " -> exit " (third result) ", " elapsed "s")
    result))

(timed-run "list /tmp"     "ls"    (list "/tmp"))
(timed-run "print date"    "date"  (list))
(timed-run "sleep 1s"      "sleep" (list "1"))
