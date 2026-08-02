;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/r7rs/ch06_14_system_interface_
;; spec.cr's own cases -- see modules/creme/spec.sld's own header comment
;; for the framework this uses, and spec/creme/r7rs/ch06_13_input_output_
;; spec.scm's own header comment for this project's existing precedent of
;; testing directly (no string-embedding-and-sub-eval, temp Dir.mkdir_p, or
;; fresh Interpreter needed, since this file already runs in a real Scheme
;; runtime, and `load`'s own filename resolves relative to the loading
;; file's own directory just like `include` -- see ch04_expressions_spec.
;; scm's own comment on that same load_dirs mechanism).
;;
;; Reuses fixtures/triple.scm (spec/creme/r7rs/fixtures/), the very same
;; fixture ch04_expressions_spec.scm's own include/include-ci cases use --
;; identical content to the original Crystal spec's own inline
;; `File.write(..., "(define (triple x) (* x 3))")`.
;;
;; `load`/`command-line`/`get-environment-variables` USED to each be a
;; genuine icecreme gap here, every one gated behind
;; `it-unless (equal? (spec-vm) "icecreme")`. All three are now fixed --
;; `load` is a real icecreme/compiler-run.scm-defined procedure now (the same
;; compile-mode-only pattern `eval`/`read`/`open-input-string` already
;; used, see that file's own comment), and `(scheme process-context)` is
;; a full port (icecreme/builtins.c's creme_register_process_context_builtins
;; used to register only `exit`) -- so every case in this file runs
;; unconditionally now.
;;
;; "exit raises a catchable Creme::SchemeExit rather than terminating the
;; host process" has no faithful port here at all, structurally: the
;; original Crystal case tests the EMBEDDING contract from Crystal's own
;; side (expect_raises(Creme::SchemeExit) catches a Crystal-level
;; exception around a fresh, disposable Creme::Interpreter). From
;; INSIDE Scheme, `exit` is deliberately NOT guard-catchable in any of
;; the three backends (see src/creme/errors.cr's own comment on
;; SchemeExit -- "Deliberately not a SchemeError... `guard` must not be
;; able to intercept" -- and icecreme/builtins.c's own bi_exit, which calls
;; the raw C exit() directly): actually invoking `(exit)` here would just
;; terminate this whole spec file's own process mid-run, taking every
;; later `it`/spec-summary! down with it. Skipped entirely rather than
;; risk that -- there is no should-raise?-shaped assertion that could
;; safely observe this from a spec file that itself needs to keep
;; running afterward.
;;
;; Run with (all cases pass, 0 pending, under all three):
;;   ./bin/creme spec/creme/r7rs/ch06_14_system_interface_spec.scm
;;   ./bin/creme --self-hosted spec/creme/r7rs/ch06_14_system_interface_spec.scm
;;   ./icecreme/icecreme spec/creme/r7rs/ch06_14_system_interface_spec.scm
;; ===========================================================================

(import (scheme base) (scheme load) (scheme file) (scheme process-context) (scheme time) (creme spec))

(describe "R7RS §6.14 System interface"
  (it "load reads and evaluates a file's expressions/definitions against the current (or a given) environment"
    (should-equal?
     (let ()
       (load "fixtures/triple.scm")
       (triple 5))
     15))

  (it "(scheme file) provides file-exists?/delete-file/open-input-file/etc. under R7RS's own standard library name"
    (let ((path "/tmp/creme-spec-r7rs-ch06-14-probe.txt"))
      (should-equal?
       (let ((before (file-exists? path)))
         (let ((op (open-output-file path)))
           (close-port op))
         (let ((after-write (file-exists? path)))
           (delete-file path)
           (list before after-write (file-exists? path))))
       (list #f #t #f))))

  (it "command-line returns the process's command line as a list of strings"
    (should-be-true? (list? (command-line))))

  (it "get-environment-variable returns #f for a name that is not set"
    (should-be-false? (get-environment-variable "NONEXISTENT_VAR_XYZ")))

  (it "get-environment-variables returns an alist of all environment variable name/value pairs"
    (should-be-true? (list? (get-environment-variables))))

  (it "current-second returns a number representing the current TAI time"
    (should-be-true? (number? (current-second))))

  (it "current-jiffy/jiffies-per-second provide an implementation-defined high-resolution clock"
    (should-equal? (list (number? (current-jiffy)) (number? (jiffies-per-second))) (list #t #t))))

(spec-summary!)
