(import (scheme base) (scheme write) (creme file) (creme regex))

(define (filter-list pred lst)
  (cond ((null? lst) '())
        ((pred (car lst)) (cons (car lst) (filter-list pred (cdr lst))))
        (else (filter-list pred (cdr lst)))))

(define log-path "/tmp/creme-example-app.log")

(file-write log-path
  (string-append
    "2026-07-10 10:00:01 INFO service started\n"
    "2026-07-10 10:00:05 ERROR E1001 failed to connect to database\n"
    "2026-07-10 10:00:07 INFO retrying connection\n"
    "2026-07-10 10:00:09 ERROR E1002 timeout waiting for response\n"
    "2026-07-10 10:00:12 INFO connection established\n"
    "2026-07-10 10:00:20 ERROR E1001 failed to connect to database\n"))

(define error-line-re (regexp "ERROR (E[0-9]+)"))
(define lines (file-lines log-path))
(define error-lines (filter-list (lambda (line) (regexp-matches? error-line-re line)) lines))

(display "Total lines: ") (display (length lines)) (newline)
(display "Error lines: ") (display (length error-lines)) (newline)
(for-each (lambda (line) (display "  ") (display line) (newline)) error-lines)

(define error-codes (map (lambda (line) (cadr (regexp-search error-line-re line))) error-lines))
(display "Error codes seen: ") (display error-codes) (newline)

(delete-file log-path)
