(import (scheme base) (scheme write) (creme logger))

;; A logger at the default 'debug threshold: everything gets written.
(define log (make-logger (current-output-port)))
(logger-debug! log "starting up")
(logger-info! log "listening on port 8080")
(logger-warn! log "cache is 90% full")
(newline)

;; Raise the threshold: only 'error and above make it through now.
(logger-level-set! log 'error)
(logger-info! log "this is suppressed -- below the new threshold")
(logger-warn! log "this is suppressed too")
(logger-error! log "database connection lost")
(logger-fatal! log "out of memory, exiting")
(newline)

;; A custom formatter, e.g. for machine-readable output.
(logger-formatter-set!
 log
 (lambda (level timestamp message)
   (string-append "level=" (symbol->string level) " msg=\"" message "\"\n")))
(logger-error! log "custom-formatted line")
