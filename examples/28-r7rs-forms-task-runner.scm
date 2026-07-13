; A tiny task runner showcasing several R7RS forms together: define-record-type
; for the task itself, named-let and do for the two ways to iterate over the
; queue, case to dispatch on task kind, and guard to keep one failing task
; from taking down the whole run.

(import (scheme base) (scheme write))

(define-record-type task
  (make-task kind payload)
  task?
  (kind task-kind)
  (payload task-payload)
  (result task-result set-task-result!))

(define (run-task t)
  (case (task-kind t)
    ((square) (let ((n (task-payload t))) (* n n)))
    ((double) (let ((n (task-payload t))) (* 2 n)))
    ((boom) (error "task exploded" (task-payload t)))
    (else (error "unknown task kind" (task-kind t)))))

(define (run-all! tasks)
  (let loop ((remaining tasks))
    (unless (null? remaining)
      (let ((t (car remaining)))
        (set-task-result! t
          (guard (e (#t (list 'failed (error-object-message e))))
            (run-task t)))
        (loop (cdr remaining))))))

(define tasks
  (list (make-task 'square 6)
        (make-task 'double 10)
        (make-task 'boom 99)
        (make-task 'square 7)))

(run-all! tasks)

(for-each
  (lambda (t) (display (task-kind t)) (display " ") (display (task-payload t)) (display " => ") (display (task-result t)) (newline))
  tasks)

; Sum of all the numeric results, skipping the failed task, computed with `do`.
(define total
  (do ((remaining tasks (cdr remaining))
       (sum 0 (let ((r (task-result (car remaining))))
                (if (number? r) (+ sum r) sum))))
      ((null? remaining) sum)))

(display "Total of successful results: ") (display total) (newline)
