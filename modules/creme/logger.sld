;; ===========================================================================
;; (creme logger): leveled logging to a port, matching Ruby's Logger
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme uri)/(creme cgi) use) since every export here is expressible in
;; plain R7RS over (creme time)'s current-time/time->string and an
;; ordinary output port, with no opaque foreign object or third-party
;; Crystal library of its own involved.
;;
;; Five severity levels, in ascending order: 'debug 'info 'warn 'error
;; 'fatal (Ruby's UNKNOWN, above fatal, is omitted -- there's no
;; "severity of an unknown severity" use case worth the extra level
;; here). A logger only writes a message whose level is >= its own
;; configured threshold level.
;;
;;   (make-logger port)                    -> a new logger writing to
;;                                             port, threshold 'debug (so
;;                                             everything is written by
;;                                             default), default formatter
;;   (make-logger port level)              -> ... with an explicit
;;                                             starting threshold level
;;   (make-logger port level formatter)    -> ... with an explicit
;;                                             formatter too (see below)
;;   (logger? x)
;;   (logger-port logger)                  -> logger's underlying port
;;   (logger-level-set! logger level)      -> changes logger's threshold,
;;                                             in place
;;   (logger-formatter-set! logger proc)   -> changes logger's formatter,
;;                                             in place -- proc is called
;;                                             as (proc level timestamp
;;                                             message) and must return
;;                                             the exact string to write
;;                                             (including its own
;;                                             trailing newline, if
;;                                             wanted); level is one of
;;                                             the five symbols above,
;;                                             timestamp is a (creme
;;                                             time) epoch float. The
;;                                             default formatter writes
;;                                             "[LEVEL] YYYY-MM-DD
;;                                             HH:MM:SS message\n" with
;;                                             no ANSI color codes -- a
;;                                             logger's output often ends
;;                                             up in a redirected file,
;;                                             where escape codes are
;;                                             noise, not help; a caller
;;                                             wanting color can supply
;;                                             its own formatter using
;;                                             (creme term) directly.
;;   (logger-debug! logger message) / (logger-info! logger message) /
;;   (logger-warn! logger message) / (logger-error! logger message) /
;;   (logger-fatal! logger message)        -> logs message at that fixed
;;                                             level (a no-op if that
;;                                             level is below logger's
;;                                             own threshold)
;;   (logger-add! logger level message)    -> the general form the above
;;                                             five are sugar for --
;;                                             level is an explicit
;;                                             symbol, Ruby's Logger#add
;;
;; Every write flushes the port immediately afterward (via
;; flush-output-port), since a log message is meant to be visible right
;; away, not buffered until something else happens to flush the port.
;;
;; Not auto-imported anywhere -- every script that wants this must
;; (import (creme logger)) explicitly, same as any other file-based
;; library.
;; ===========================================================================

(define-library (creme logger)
  (export make-logger logger? logger-port logger-level-set!
          logger-formatter-set! logger-debug! logger-info! logger-warn!
          logger-error! logger-fatal! logger-add!)
  (import (scheme base) (scheme write) (creme time) (only (creme string) string-upcase))
  (begin
    (define logger-priv-level-rank
      (list (cons 'debug 0) (cons 'info 1) (cons 'warn 2) (cons 'error 3) (cons 'fatal 4)))

    (define (logger-priv-rank level)
      (let ((entry (assq level logger-priv-level-rank)))
        (if entry (cdr entry) (error "logger: unknown level" level))))

    (define (logger-priv-level-name level) (string-upcase (symbol->string level)))

    ;; string-upcase comes from (creme string) (imported above). Level names
    ;; are always plain ASCII symbols, so its result matches the old local
    ;; ASCII-only version for every value this library calls it with.

    (define (logger-priv-default-formatter level timestamp message)
      (string-append
       "[" (logger-priv-level-name level) "] "
       (time->string timestamp "%Y-%m-%d %H:%M:%S") " " message "\n"))

    (define-record-type <logger>
      (make-logger-record port level formatter)
      logger?
      (port logger-port)
      (level logger-priv-level logger-priv-level-set!)
      (formatter logger-priv-formatter logger-priv-formatter-set!))

    (define (make-logger port . opts)
      (make-logger-record
       port
       (if (>= (length opts) 1) (car opts) 'debug)
       (if (>= (length opts) 2) (cadr opts) logger-priv-default-formatter)))

    (define (logger-level-set! logger level) (logger-priv-level-set! logger level))
    (define (logger-formatter-set! logger proc) (logger-priv-formatter-set! logger proc))

    (define (logger-add! logger level message)
      (if (>= (logger-priv-rank level) (logger-priv-rank (logger-priv-level logger)))
          (begin
            (display ((logger-priv-formatter logger) level (current-time) message) (logger-port logger))
            (flush-output-port (logger-port logger)))))

    (define (logger-debug! logger message) (logger-add! logger 'debug message))
    (define (logger-info! logger message) (logger-add! logger 'info message))
    (define (logger-warn! logger message) (logger-add! logger 'warn message))
    (define (logger-error! logger message) (logger-add! logger 'error message))
    (define (logger-fatal! logger message) (logger-add! logger 'fatal message))))
