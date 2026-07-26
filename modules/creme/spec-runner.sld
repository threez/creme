;; ===========================================================================
;; (creme spec-runner): drives spec/creme's own "run every *_spec.scm file
;; and report ONE combined total" entry point (spec/creme/main_spec.scm).
;;
;; Each spec file still runs as its own separate OS process (via (creme
;; process)'s process-run), NOT loaded/reentrant-compiled into this same
;; process -- deliberately: several spec files (prim_call_spec.scm,
;; compiler_defmacro_spec.scm) intentionally end by PERMANENTLY redefining
;; a widely-used builtin (+, car, vector-ref, ...) to test deopt behavior,
;; which is exactly why each needs its own fresh global table. Combining
;; every file into one shared interpreter would need a hand-maintained
;; load order (corrupting files last) that's one careless future edit
;; away from silently breaking every OTHER file that runs after it. A
;; genuinely separate process per file sidesteps that risk entirely, the
;; same way Crystal's own spec_helper.cr gives each individual `w`/`run`
;; call a brand new Scheme::Interpreter.
;;
;; What THIS library adds is just the aggregation: run-spec-file! spawns
;; one spec file, parses that CHILD process's own already-printed final
;; "N examples, M failures" line (spec.sld's own spec-summary! output --
;; plain/uncolored here since the child's stdout, captured into a string
;; by process-run, is never a tty -- see spec.sld's own stdout-tty?
;; check), and folds those counts into the CALLING process's own totals
;; via (creme spec)'s spec-record-external-result!, so a driver script
;; can call (spec-summary!) once at the end and get one real combined
;; number instead of 13 separate per-file reports the caller has to add
;; up by hand.
;;
;; A separate library from (creme spec) itself specifically so (creme
;; spec)'s own dependency footprint doesn't grow: (creme string) is
;; native-Crystal-only (no .sld, no cvm C equivalent), and (creme spec)
;; is imported by EVERY spec/creme/*.scm file, including every one
;; already passing under cvm's self-hosted loader today. Only spec/
;; creme/main_spec.scm needs this library at all.
;;
;; (creme process)'s process-run itself now works under all three
;; backends: cvm's own cvm/process.c backs it with plain POSIX fork/
;; pipe/execvp/waitpid, matching native Crystal's exact contract -- so
;; `./cvm/cvm spec/creme/main_spec.scm` spawns real `./cvm/cvm <file>`
;; subprocesses the same way `./bin/creme spec/creme/main_spec.scm
;; --cvm` does, no different code path needed here for that case.
;; ===========================================================================

(define-library (creme spec-runner)
  (export run-spec-file!)
  (import (scheme base) (scheme cxr) (scheme write) (creme process) (creme string) (creme spec))
  (begin
    ;; The last line in `lines` shaped like spec-summary!'s own output --
    ;; last, not first, in case anything earlier in the child's own
    ;; stdout ever happens to contain a same-shaped line (should-equal?
    ;; failure messages could in principle echo arbitrary text).
    (define (spec-runner-find-summary-line lines)
      (let loop ((ls lines) (found #f))
        (cond
          ((null? ls) found)
          ((and (string-contains? (car ls) " examples, ") (string-suffix? (car ls) " failures"))
           (loop (cdr ls) (car ls)))
          (else (loop (cdr ls) found)))))

    ;; line is exactly "N examples, M failures" -- split it back into the
    ;; two integers spec-record-external-result! needs.
    (define (spec-runner-parse-counts line)
      (let* ((ex-pos (string-index-of line " examples, "))
             (n (string->number (substring line 0 ex-pos)))
             (after (substring line (+ ex-pos (string-length " examples, ")) (string-length line)))
             (fail-pos (string-index-of after " failures"))
             (m (string->number (substring after 0 fail-pos))))
        (cons n m)))

    ;; `runner` is a list of strings, the command + any leading args to
    ;; run `path` with -- e.g. '("./bin/creme"), '("./bin/creme"
    ;; "--self-hosted"), or '("./cvm/cvm"). Always prints the child's own
    ;; full captured output (so an individual failure is still fully
    ;; diagnosable from the combined run, not just a bare count), then
    ;; folds its reported counts into this process's own totals. If the
    ;; child never printed a summary line at all (a crash/compile error
    ;; before spec-summary! ever ran), records it as a single synthetic
    ;; failure rather than silently dropping it from the total.
    (define (run-spec-file! runner path)
      (display "== ") (display path) (display " ==") (newline)
      (let* ((result (process-run (car runner) (append (cdr runner) (list path))))
             (out (car result))
             (err (cadr result))
             (code (caddr result))
             (summary (spec-runner-find-summary-line (string-split out "\n"))))
        (display out)
        (if summary
            (let ((counts (spec-runner-parse-counts summary)))
              (spec-record-external-result! path (car counts) (cdr counts)))
            (begin
              (if (> (string-length err) 0) (begin (display err) (newline)))
              (display "  (no \"N examples, M failures\" line -- process exited with code ")
              (display code) (display " before printing one)") (newline)
              (spec-record-external-result! path 1 1)))))))
