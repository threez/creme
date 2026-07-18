;; ===========================================================================
;; (creme shell): ergonomic, bench-script-oriented helpers over (creme process)
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme cli)/(creme wrk)/(creme extra) use) rather than compiled into the
;; interpreter binary, since every export here is expressible in plain R7RS
;; on top of (creme process)'s own process-run/process-spawn/sleep!, with no
;; opaque foreign object or third-party Crystal library of its own involved —
;; see modules/creme/extra.sld's own header comment for the same rationale.
;;
;;   (shell-run cmd args)              -> an alist-returning wrapper over
;;                                         process-run:
;;                                           (("stdout" . ...) ("stderr" . ...)
;;                                            ("status" . ...) ("success" . ...))
;;                                         instead of forcing callers to
;;                                         destructure process-run's plain
;;                                         positional (stdout stderr status
;;                                         success) list with car/cadr/
;;                                         caddr/cadddr.
;;   (shell-checked! cmd args who)     -> like shell-run, but raises
;;                                         (error "shell-checked!: WHO failed"
;;                                                stderr)
;;                                         if the command didn't exit
;;                                         successfully; otherwise returns
;;                                         the same alist shell-run does.
;;   (shell-kill-pattern! pattern)     -> (process-run "pkill" (list "-f"
;;                                         pattern)) -- a defensive "clean up
;;                                         anything stale from a previous
;;                                         crashed run" tool, matched by
;;                                         process command-line pattern, NOT
;;                                         the primary way a script should
;;                                         kill what it itself spawned (use
;;                                         process-kill! by pid for that).
;;   (shell-wait-until! pred-thunk . kvs) -> generic polling loop:
;;                                         'attempts N (default 50),
;;                                         'interval SECONDS (default 0.1).
;;                                         Calls (pred-thunk) each attempt;
;;                                         returns #t the first time it's
;;                                         truthy, sleeping 'interval
;;                                         seconds (via sleep!) between
;;                                         tries. Raises
;;                                           (error "shell-wait-until!: timed out" attempts)
;;                                         — an ordinary catchable Scheme
;;                                         error a caller can (guard) around
;;                                         and customize — after 'attempts
;;                                         tries with no success.
;;
;; Not auto-imported anywhere — every script that wants any of this must
;; (import (creme shell)) explicitly, same as any other file-based library.
;; ===========================================================================

(define-library (creme shell)
  (export shell-run shell-checked! shell-kill-pattern! shell-wait-until!)
  (import (scheme base) (scheme cxr) (creme process))
  (begin
    (define (kv-ref kvs key default)
      (cond
       ((null? kvs) default)
       ((eq? (car kvs) key) (cadr kvs))
       (else (kv-ref (cddr kvs) key default))))

    ;; (shell-run cmd args) -> see this file's own header comment.
    (define (shell-run cmd args)
      (let ((result (process-run cmd args)))
        (list (cons "stdout" (car result))
              (cons "stderr" (cadr result))
              (cons "status" (caddr result))
              (cons "success" (cadddr result)))))

    ;; (shell-checked! cmd args who) -> see this file's own header comment.
    (define (shell-checked! cmd args who)
      (let ((result (shell-run cmd args)))
        (if (cdr (assoc "success" result))
            result
            (error (string-append "shell-checked!: " who " failed")
                   (cdr (assoc "stderr" result))))))

    ;; (shell-kill-pattern! pattern) -> see this file's own header comment.
    (define (shell-kill-pattern! pattern)
      (process-run "pkill" (list "-f" pattern)))

    ;; (shell-wait-until! pred-thunk . kvs) -> see this file's own header
    ;; comment.
    (define (shell-wait-until! pred-thunk . kvs)
      (let ((attempts (kv-ref kvs 'attempts 50))
            (interval (kv-ref kvs 'interval 0.1)))
        (let loop ((attempt 0))
          (cond
           ((pred-thunk) #t)
           ((>= attempt attempts) (error "shell-wait-until!: timed out" attempts))
           (else (sleep! interval) (loop (+ attempt 1)))))))))
