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
;; call a brand new Creme::Interpreter.
;;
;; What THIS library adds is the aggregation: run-spec-file! sets
;; CREME_SPEC_DATA_MODE (an environment variable a spawned child
;; inherits automatically -- see (creme spec)'s own header comment) so
;; the child's own spec-summary! `write`s its whole result as ONE
;; Scheme value (total failed tree) instead of printing human-readable
;; text, reads that value back via `read`, renders the tree in THIS
;; process via (creme spec)'s render-spec-tree! (so [PASS]/[FAIL] get
;; colored according to the PARENT's own terminal, not the child's --
;; the child's captured stdout is never a tty, so it would otherwise
;; always render colorless even when the whole run is happening at a
;; real terminal), and folds the counts into this process's own totals
;; via spec-record-external-result!, so a driver script can call
;; (spec-summary!) once at the end and get one real combined number
;; instead of 13 separate per-file reports the caller has to add up by
;; hand.
;;
;; A separate library from (creme spec) itself specifically so (creme
;; spec)'s own dependency footprint doesn't grow: (creme env)/(creme
;; process) are both native-Crystal-only from Crystal's point of view
;; (though cvm now backs both process-run and set-environment-variable!
;; too -- see cvm/process.c and cvm/builtins.c), and (creme spec) is
;; imported by EVERY spec/creme/*.scm file, including every one already
;; passing under cvm's self-hosted loader today. Only spec/creme/
;; main_spec.scm needs this library at all.
;;
;; (creme process)'s process-run works under all three backends: cvm's
;; own cvm/process.c backs it with plain POSIX fork/pipe/execvp/waitpid,
;; matching native Crystal's exact contract -- so `./cvm/cvm spec/creme/
;; main_spec.scm` spawns real `./cvm/cvm <file>` subprocesses the same
;; way `./bin/creme spec/creme/main_spec.scm --cvm` does, no different
;; code path needed here for that case. Likewise set-environment-
;; variable! -- a subprocess inherits its parent's environ automatically
;; (execvp/Process.run don't touch it), so setting the flag once here
;; works whether THIS process is itself native or cvm.
;; ===========================================================================

(define-library (creme spec-runner)
  (export run-spec-file!)
  (import (scheme base) (scheme cxr) (scheme write) (scheme read)
          (creme env) (creme process) (creme string) (creme spec))
  (begin
    ;; The child's own stdout is the WHOLE captured output, which can
    ;; include stray display/write text from the file's own test bodies
    ;; (several genuinely print things as part of what they're testing)
    ;; before spec-data-marker ever appears -- so this searches for that
    ;; exact marker rather than assuming the value is the first (or
    ;; only) datum in the stream, then reads back whatever comes after
    ;; it. #f if the marker never appears at all (the child crashed/
    ;; errored before spec-summary! ran).
    (define (spec-runner-extract-value out)
      (let ((marker-pos (string-index-of out spec-data-marker)))
        (if marker-pos
            (guard (e (#t #f))
              (read (open-input-string (substring out (+ marker-pos (string-length spec-data-marker)) (string-length out)))))
            #f)))

    (define (run-spec-file! runner path)
      (display "== ") (display path) (display " ==") (newline)
      (set-environment-variable! "CREME_SPEC_DATA_MODE" "1")
      (let* ((result (process-run (car runner) (append (cdr runner) (list path))))
             (out (car result))
             (err (cadr result))
             (code (caddr result))
             (parsed (spec-runner-extract-value out)))
        ;; (total failed pending tree) -- see (creme spec)'s spec-summary!
        ;; for the writer side of this same shape.
        (if (and (pair? parsed) (= (length parsed) 4) (integer? (car parsed)) (integer? (cadr parsed)) (integer? (caddr parsed)))
            (begin
              (render-spec-tree! (cadddr parsed))
              (spec-record-external-result! path (car parsed) (cadr parsed) (caddr parsed)))
            (begin
              (display out)
              (if (> (string-length err) 0) (begin (display err) (newline)))
              (display "  (no valid (total failed pending tree) value read back -- process exited with code ")
              (display code) (display " before spec-summary! ever ran)") (newline)
              (spec-record-external-result! path 1 1 0)))))))
