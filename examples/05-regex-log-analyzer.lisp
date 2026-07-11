(require 'file)
(require 'regex)

(define log-path "/tmp/crisp-example-app.log")

(file:write log-path
  (string-append
    "2026-07-10 10:00:01 INFO service started\n"
    "2026-07-10 10:00:05 ERROR E1001 failed to connect to database\n"
    "2026-07-10 10:00:07 INFO retrying connection\n"
    "2026-07-10 10:00:09 ERROR E1002 timeout waiting for response\n"
    "2026-07-10 10:00:12 INFO connection established\n"
    "2026-07-10 10:00:20 ERROR E1001 failed to connect to database\n"))

(define error-line-re (regex:compile "ERROR (E[0-9]+)"))
(define lines (file:lines log-path))
(define error-lines (filter (lambda (line) (regex:match? error-line-re line)) lines))

(println "Total lines: " (length lines))
(println "Error lines: " (length error-lines))
(for-each (lambda (line) (println "  " line)) error-lines)

(define error-codes (map (lambda (line) (cadr (regex:match error-line-re line))) error-lines))
(println "Error codes seen: " error-codes)

(file:delete log-path)
