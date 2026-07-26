;; ===========================================================================
;; (creme spec): a minimal RSpec-like test framework, written in Creme
;; itself -- so specs for the self-hosted compiler (or any other creme.*
;; library) can be written and RUN entirely in Scheme, with no Crystal spec
;; process involved, exercising exactly the same self-hosted-compiler code
;; path a real script would.
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme extra)/(creme for) use) rather than compiled into the interpreter
;; binary -- see modules/creme/extra.sld's own header comment for the same
;; rationale: every export here is expressible in plain R7RS.
;;
;; [PASS]/[FAIL] and the final summary line are colored green/red when
;; STDOUT is an actual terminal (stdout-tty?, (creme introspection)) and
;; NO_COLOR (https://no-color.org) isn't set -- piping/redirecting output
;; (CI logs, `| tee`, a file) automatically gets plain, escape-code-free
;; text, no flag needed either way.
;;
;;   (describe "description" body ...)  -> runs body (an implicit begin),
;;                                         printed at the current nesting
;;                                         depth. `describe` blocks nest
;;                                         freely -- each one increases the
;;                                         indent for whatever it wraps.
;;   (it "description" body ...)        -> runs body as one test case.
;;                                         Passes if body returns normally;
;;                                         fails if body raises ANYTHING
;;                                         (a should-*? failure below, or an
;;                                         ordinary error/raise) -- the
;;                                         first failing expectation aborts
;;                                         the rest of that one `it`, same
;;                                         as RSpec/most xUnit frameworks
;;                                         (not a soft multi-assert mode).
;;                                         Printed immediately as it runs,
;;                                         PASS or FAIL plus the failure
;;                                         message.
;;   (should-equal? actual expected)    -> `equal?`-fails with a message
;;                                         showing both sides, else `#t`.
;;   (should-eqv? actual expected)      -> same, via `eqv?`.
;;   (should-be-true? actual)           -> fails unless actual is truthy
;;                                         (anything but `#f`).
;;   (should-be-false? actual)          -> fails unless actual is `#f`.
;;   (should-raise? thunk)              -> calls (thunk); fails if it
;;                                         returns normally instead of
;;                                         raising, else `#t`. Use to test
;;                                         a compiler/reader error path.
;;   (spec-summary!)                    -> prints a final "N examples, M
;;                                         failures" line (plus each
;;                                         failure's full description and
;;                                         message), then calls (exit 0)
;;                                         if every `it` passed or (exit 1)
;;                                         if any failed -- ends the
;;                                         process, same as a real test
;;                                         runner's own exit code, so
;;                                         `./bin/creme some_spec.scm` is
;;                                         directly usable from a Makefile/
;;                                         CI step. Always call this LAST.
;;
;; `describe`/`it` are `define-syntax`/`syntax-rules` macros (not
;; `defmacro`), matching (creme for)'s own precedent/rationale (see its
;; header comment): no dynamic name synthesis happens here, just wrapping
;; a body in a thunk, so `defmacro`'s extra `@global`-only-transformer-body
;; restriction would buy nothing. Their expansions call ONLY the ordinary
;; procedures this library exports (spec-describe!/spec-it! themselves,
;; alongside the should-*? family) -- required since a macro's expansion is
;; analyzed against the CALLING site's own environment, not this library's
;; (see (creme for)'s header comment for the same rule): every name an
;; expansion references must already be visible wherever `describe`/`it`
;; are used, which "visible because this library exports it and the spec
;; file imports this library" satisfies for free.
;;
;; `describe`/`it` also work fine reentrant under `cvm/cvm` (cvm's own
;; standalone C11 VM, running the self-hosted compiler directly -- see
;; cvm/compiler-run.scm): a spec file's own `(import (creme spec))`
;; triggers the self-hosted compiler's own library loader (ensure-
;; libraries-loaded!, compiler.sld) to read+reentrant-compile THIS
;; library's source, registering describe/it into that SAME compile
;; session's own macro-table -- entirely a Scheme-level, compile-time
;; mechanism, independent of cvm's separate (and narrower) expand-if-
;; macro Crystal-bridge (cvm/bootstrap.c, which only recognizes a
;; `defmacro`-defined macro exported from an ALREADY-compiled bytecode
;; library, e.g. sxql-select! precompiled into an image -- a different,
;; narrower scenario this project's own spec files don't hit). So run
;; with `./cvm/cvm some_spec.scm` directly (not `./bin/creme --cvm
;; some_spec.scm`, which is unrelated -- native-compile-then-run-on-cvm,
;; never touching the self-hosted compiler at all).
;;
;; Not auto-imported anywhere -- every script that wants any of this must
;; (import (creme spec)) explicitly, same as any other file-based library.
;; ===========================================================================

(define-library (creme spec)
  (export describe it
          should-equal? should-eqv? should-be-true? should-be-false? should-raise?
          spec-describe! spec-it! spec-summary! spec-record-external-result!)
  (import (scheme base) (scheme write) (scheme process-context) (creme introspection))
  (begin
    ;; ANSI color, only when it'll actually help: STDOUT must be a real
    ;; terminal (stdout-tty?, (creme introspection) -- native Crystal's
    ;; STDOUT.tty? and cvm's isatty(STDOUT_FILENO), kept in sync so this
    ;; behaves the same under bin/creme, --self-hosted, and cvm/cvm), and
    ;; NO_COLOR (https://no-color.org) must be unset -- its mere presence,
    ;; any value, opts out, same convention as most other CLI tools. Not
    ;; re-checked per describe!/it! call: computed once at library-load
    ;; time, since neither of these can change mid-run.
    (define spec-use-color? (and (stdout-tty?) (not (get-environment-variable "NO_COLOR"))))

    (define (spec-colorize code text)
      (if spec-use-color?
          (string-append "\x1b;[" code "m" text "\x1b;[0m")
          text))
    ;; A distinct condition type for should-*?'s own failures, so
    ;; spec-condition-message below can show a clean, purpose-written
    ;; message for those while still handling an ordinary (error ...)/
    ;; uncaught runtime error raised from inside an `it` body (e.g. a
    ;; genuine compiler bug the test is exercising) reasonably too.
    (define-record-type <spec-failure>
      (make-spec-failure message)
      spec-failure?
      (message spec-failure-message))

    (define (spec-fail! message) (raise (make-spec-failure message)))

    (define (write-to-string v)
      (let ((port (open-output-string)))
        (write v port)
        (get-output-string port)))

    (define (spec-condition-message e)
      (cond
        ((spec-failure? e) (spec-failure-message e))
        ((error-object? e)
         (string-append (error-object-message e)
                         (if (null? (error-object-irritants e))
                             ""
                             (string-append " " (write-to-string (error-object-irritants e))))))
        (else (string-append "non-error value raised: " (write-to-string e)))))

    (define (should-equal? actual expected)
      (if (equal? actual expected)
          #t
          (spec-fail! (string-append "expected " (write-to-string expected) ", got " (write-to-string actual)))))

    (define (should-eqv? actual expected)
      (if (eqv? actual expected)
          #t
          (spec-fail! (string-append "expected " (write-to-string expected) ", got " (write-to-string actual) " (eqv?)"))))

    (define (should-be-true? actual)
      (if actual #t (spec-fail! (string-append "expected a true value, got " (write-to-string actual)))))

    (define (should-be-false? actual)
      (if (not actual) #t (spec-fail! (string-append "expected #f, got " (write-to-string actual)))))

    (define (should-raise? thunk)
      (if (guard (e (#t #t)) (thunk) #f)
          #t
          (spec-fail! "expected an error to be raised, but none was")))

    ;; ---- runner state -------------------------------------------------------
    ;; Plain top-level mutable variables, not a parameter object -- this
    ;; runs one spec file per process, single-threaded, start to finish, so
    ;; there's no dynamic-extent/re-entrancy need a parameter would buy.
    (define spec-depth 0)
    (define spec-total 0)
    (define spec-failed 0)
    (define spec-failures '()) ; list of (full-name . message), most recent first

    (define (spec-indent) (make-string (* spec-depth 2) #\space))

    ;; Innermost-first list of enclosing `describe` names, joined with
    ;; " > " for a failure's full-path label in the final summary (e.g.
    ;; "self-hosted compiler > arithmetic > adds three numbers").
    (define spec-path '())

    (define (spec-full-name name)
      (if (null? spec-path)
          name
          (string-append
            (let loop ((path (reverse spec-path)))
              (if (null? (cdr path))
                  (car path)
                  (string-append (car path) " > " (loop (cdr path)))))
            " > " name)))

    (define (spec-describe! name thunk)
      (display (spec-indent)) (display name) (newline)
      (set! spec-depth (+ spec-depth 1))
      (set! spec-path (cons name spec-path))
      (thunk)
      (set! spec-path (cdr spec-path))
      (set! spec-depth (- spec-depth 1)))

    (define (spec-it! name thunk)
      (set! spec-total (+ spec-total 1))
      (guard (e (#t
                 (set! spec-failed (+ spec-failed 1))
                 (set! spec-failures (cons (cons (spec-full-name name) (spec-condition-message e)) spec-failures))
                 (display (spec-indent)) (display (spec-colorize "31" "[FAIL]")) (display " ") (display name) (newline)))
        (thunk)
        (display (spec-indent)) (display (spec-colorize "32" "[PASS]")) (display " ") (display name) (newline)))

    ;; Folds another spec FILE's own already-reported "N examples, M
    ;; failures" counts into this process's own totals -- (creme spec-
    ;; runner)'s run-spec-file! calls this once per external file it
    ;; spawns as its own subprocess (see that library's own header
    ;; comment for why a subprocess, not just loading the file's forms
    ;; into this same process). Deliberately just two integers in, not a
    ;; whole condition/thunk -- this library itself takes on no new
    ;; dependency (no (creme process)/(creme string) import here) so
    ;; every EXISTING spec file that merely imports (creme spec) for
    ;; describe/it, including every one already passing under cvm, is
    ;; completely unaffected; only (creme spec-runner) needs those.
    (define (spec-record-external-result! name n failed)
      (set! spec-total (+ spec-total n))
      (set! spec-failed (+ spec-failed failed))
      (if (> failed 0)
          (set! spec-failures
            (cons (cons name (string-append (number->string failed) " of " (number->string n)
                               " examples failed in this externally-run file -- see its own output above"))
                  spec-failures))))

    (define (spec-summary!)
      (newline)
      (display (spec-colorize (if (> spec-failed 0) "31" "32")
                 (string-append (number->string spec-total) " examples, " (number->string spec-failed) " failures")))
      (newline)
      (if (> spec-failed 0)
          (begin
            (newline)
            (for-each
              (lambda (f)
                (display "  ") (display (spec-colorize "31" (car f))) (display ":") (newline)
                (display "    ") (display (cdr f)) (newline))
              (reverse spec-failures))
            (exit 1))
          (exit 0)))

    (define-syntax describe
      (syntax-rules ()
        ((_ name body ...) (spec-describe! name (lambda () body ...)))))

    (define-syntax it
      (syntax-rules ()
        ((_ name body ...) (spec-it! name (lambda () body ...)))))))
