;; (creme process): thin re-export frontend over (creme builtin process),
;; plus process-run-safe, a small pure-Scheme helper built on top of it.
(define-library (creme process)
  (import (scheme base) (scheme cxr) (creme builtin process))
  (export command-line process-alive? process-kill! process-run
          process-run-safe process-spawn process-wait! process-write-line!
          sleep! sleep-ms!)
  (begin
    ;; Runs cmd/args via process-run, returning its stdout on a clean exit
    ;; or #f if the command raised (not found, etc.) or exited nonzero --
    ;; the "every comparison variant is optional" pattern shared by
    ;; competition/bench.scm's two suites (CPU workloads across language
    ;; runtimes, HTTP-benchmarked demo-todo twins): a missing/unbuilt/
    ;; failing variant falls back to "n/a" instead of raising and stopping
    ;; the whole run.
    (define (process-run-safe cmd args)
      (guard (e (#t #f))
        (let* ((result (process-run cmd args))
               (out (car result))
               (success (cadddr result)))
          (if success out #f))))))
