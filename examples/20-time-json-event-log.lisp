(require 'time)
(require 'json)
(require 'file)

(define log-path "/tmp/crisp-example-events.jsonl")

(define (log-event! kind message)
  (define entry (list (cons "ts" (time:now)) (cons "kind" kind) (cons "message" message)))
  (file:append log-path (string-append (json:stringify entry) "\n")))

(file:write log-path "")
(log-event! "startup"  "service booting")
(log-event! "info"     "connected to database")
(log-event! "warning"  "cache miss rate high")
(log-event! "info"     "request served")
(log-event! "shutdown" "service stopping")

(define events
  (map json:parse (filter (lambda (l) (> (string-length l) 0)) (file:lines log-path))))

(println "Total events: " (length events))

(define (event-kind e) (cdr (assoc "kind" e)))

(define (count-kind kind)
  (length (filter (lambda (e) (string=? (event-kind e) kind)) events)))

(for-each
  (lambda (k) (println k ": " (count-kind k)))
  (list "startup" "info" "warning" "shutdown"))

(file:delete log-path)
