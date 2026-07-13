(import (scheme base) (scheme write) (creme time) (creme json) (creme file))

(define (filter-list pred lst)
  (cond ((null? lst) '())
        ((pred (car lst)) (cons (car lst) (filter-list pred (cdr lst))))
        (else (filter-list pred (cdr lst)))))

(define log-path "/tmp/creme-example-events.jsonl")

(define (log-event! kind message)
  (define entry (list (cons "ts" (current-time)) (cons "kind" kind) (cons "message" message)))
  (file-append log-path (string-append (json-write entry) "\n")))

(file-write log-path "")
(log-event! "startup"  "service booting")
(log-event! "info"     "connected to database")
(log-event! "warning"  "cache miss rate high")
(log-event! "info"     "request served")
(log-event! "shutdown" "service stopping")

(define events
  (map json-read (filter-list (lambda (l) (> (string-length l) 0)) (file-lines log-path))))

(display "Total events: ") (display (length events)) (newline)

(define (event-kind e) (cdr (assoc "kind" e)))

(define (count-kind kind)
  (length (filter-list (lambda (e) (string=? (event-kind e) kind)) events)))

(for-each
  (lambda (k) (display k) (display ": ") (display (count-kind k)) (newline))
  (list "startup" "info" "warning" "shutdown"))

(delete-file log-path)
