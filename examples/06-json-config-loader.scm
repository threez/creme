(import (scheme base) (scheme write) (creme file) (creme json) (creme env))

(define config-path "/tmp/creme-example-config.json")

(file-write config-path "{\"host\":\"localhost\",\"port\":8080,\"debug\":false}")
(set-environment-variable! "CREME_EXAMPLE_PORT" "9090")

(define config (json-read (file-read config-path)))

(define (config-ref key default)
  (let ((entry (assoc key config)))
    (if entry (cdr entry) default)))

(define port
  (let ((override (get-environment-variable "CREME_EXAMPLE_PORT")))
    (if override (string->number override) (config-ref "port" 8080))))

(display "host:  ") (display (config-ref "host" "localhost")) (newline)
(display "port:  ") (display port) (display " (overridden by CREME_EXAMPLE_PORT env var; config file said ") (display (config-ref "port" 8080)) (display ")") (newline)
(display "debug: ") (display (config-ref "debug" #f)) (newline)

(delete-file config-path)
(delete-environment-variable! "CREME_EXAMPLE_PORT")
