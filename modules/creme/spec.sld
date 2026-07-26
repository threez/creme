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
;; A caveat shared with every other `define-syntax` library in this project:
;; cvm's own reentrant self-hosted-compiler bridge (cvm/bootstrap.c) only
;; expands `defmacro`-defined macros exported from an already-compiled
;; library, not `syntax-rules` ones (a real, documented, still-open gap --
;; see that file's own header comment) -- so a spec file using `describe`/
;; `it` runs fine via a plain `./bin/creme some_spec.scm` or `./bin/creme
;; --self-hosted some_spec.scm`, but not yet via `./bin/creme --cvm
;; some_spec.scm`.
;;
;; Not auto-imported anywhere -- every script that wants any of this must
;; (import (creme spec)) explicitly, same as any other file-based library.
;; ===========================================================================

(define-library (creme spec)
  (export describe it
          should-equal? should-eqv? should-be-true? should-be-false? should-raise?
          spec-describe! spec-it! spec-summary!)
  (import (scheme base) (scheme write) (scheme process-context))
  (begin
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
                 (display (spec-indent)) (display "[FAIL] ") (display name) (newline)))
        (thunk)
        (display (spec-indent)) (display "[PASS] ") (display name) (newline)))

    (define (spec-summary!)
      (newline)
      (display spec-total) (display " examples, ") (display spec-failed) (display " failures")
      (newline)
      (if (> spec-failed 0)
          (begin
            (newline)
            (for-each
              (lambda (f)
                (display "  ") (display (car f)) (display ":") (newline)
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
