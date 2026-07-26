;; ===========================================================================
;; (creme compiler spec-helper): shared plumbing for spec/creme/compiler_*
;; .scm files -- factored out purely to keep those spec files themselves
;; concise; nothing here is part of the compiler's own public API, and no
;; non-spec code should ever need to import this.
;;
;;   (bootstrap-eval src)      -> reads+compiles src (a string of one or
;;                                 more top-level forms) with the SELF-
;;                                 HOSTED compiler (compile-source-to-
;;                                 bytes/load-chunk-bytes) and runs it,
;;                                 returning the last form's value.
;;   (native-eval src)         -> reads+evaluates the same src through
;;                                 plain native evaluation (the native
;;                                 reader plus (scheme eval)'s `eval`,
;;                                 form by form), returning the last
;;                                 form's value -- the "known correct"
;;                                 side of a comparison.
;;   (write-to-string v)       -> v's `write` representation as a string.
;;   (should-match-native? src)-> should-equal?s bootstrap-eval's result
;;                                 against native-eval's result, both via
;;                                 write-to-string (robust to values, like
;;                                 records, `equal?` doesn't necessarily
;;                                 consider interchangeable even when they
;;                                 print identically) -- this is the one
;;                                 call most spec/creme/compiler_*.scm
;;                                 cases make. `src` is either a STRING
;;                                 (read+compiled via compile-source-to-
;;                                 bytes, exercising the reader too) or a
;;                                 quoted LIST OF FORMS (compiled directly
;;                                 via compile-program, skipping the
;;                                 reader) -- pass whichever a given case
;;                                 reads more naturally; a list needs no
;;                                 `\"`-escaping for embedded strings and
;;                                 allows ordinary multi-line formatting,
;;                                 a string is occasionally more direct
;;                                 for source built up dynamically (e.g.
;;                                 via string-append).
;;   (read-all-native src)     -> every top-level form in src, read by the
;;                                 native reader -- the "native" side for
;;                                 a test that checks the self-hosted
;;                                 reader's own read-program output.
;;   compile-source-to-bytes, load-chunk-bytes -- (creme compiler
;;                                 compiler)/(creme bootstrap)'s own exports,
;;                                 re-exported here so a spec file that needs
;;                                 them directly (e.g. to should-raise? on a
;;                                 bad compile) doesn't also need its own
;;                                 (import (creme compiler compiler) (creme
;;                                 bootstrap)).
;;   (library-body-source path)-> the (begin form1 form2 ...) clause's own
;;                                 forms out of a (define-library (creme
;;                                 name) (export ...) (import ...) (begin
;;                                 ...)) file at `path`, re-printed as
;;                                 source text (one form per line) -- what
;;                                 a self-compile test needs to feed BACK
;;                                 into compile-source-to-bytes, since
;;                                 that compiles a flat sequence of
;;                                 top-level forms, not a define-library
;;                                 wrapper.
;;
;; should-match-native?/bootstrap-eval both run against THIS ONE PROCESS's
;; single shared global table (load-chunk-bytes always loads into the
;; running interpreter's own global -- there's no isolated-environment
;; option) -- harmless for a test that defines/uses ordinary names, but a
;; test that redefines a widely-used name like `+`/`car` permanently
;; mutates it for every later should-match-native? call in the same
;; process. See compiler_defmacro_spec.scm's own note on its fusion-
;; suppression-after-redefinition cases (which avoid should-match-native?
;; for exactly this reason) and compiler_self_host_spec.scm's own note on
;; why its register-safety case must run BEFORE its self-hosting cases.
;;
;; Not auto-imported anywhere -- every spec file that wants any of this
;; must (import (creme compiler spec-helper)) explicitly, same as any
;; other file-based library.
;; ===========================================================================

(define-library (creme compiler spec-helper)
  (export bootstrap-eval native-eval write-to-string should-match-native?
          bootstrap-eval-forms native-eval-forms
          read-all-native library-body-source
          compile-source-to-bytes load-chunk-bytes read-program compile-program chunk->bytes)
  (import (scheme base) (scheme write) (scheme read) (scheme eval) (scheme lazy)
          (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
          (creme compiler reader) (creme compiler compiler)
          (creme file) (creme string) (creme spec))
  (begin
    (define (write-to-string v)
      (let ((port (open-output-string)))
        (write v port)
        (get-output-string port)))

    (define (native-eval src)
      (let ((in (open-input-string src)))
        (let loop ((result (if #f #f)))
          (let ((form (read in)))
            (if (eof-object? form)
                result
                (loop (eval form)))))))

    (define (bootstrap-eval src)
      (load-chunk-bytes (compile-source-to-bytes src)))

    (define (native-eval-forms forms)
      (let loop ((fs forms) (result (if #f #f)))
        (if (null? fs)
            result
            (loop (cdr fs) (eval (car fs))))))

    (define (bootstrap-eval-forms forms)
      (load-chunk-bytes (chunk->bytes (compile-program forms))))

    (define (should-match-native? src)
      (if (string? src)
          (should-equal? (write-to-string (bootstrap-eval src)) (write-to-string (native-eval src)))
          (should-equal? (write-to-string (bootstrap-eval-forms src)) (write-to-string (native-eval-forms src)))))

    (define (read-all-native src)
      (let ((in (open-input-string src)))
        (let loop ((acc '()))
          (let ((form (read in)))
            (if (eof-object? form)
                (reverse acc)
                (loop (cons form acc)))))))

    (define (find-begin-clause clauses)
      (cond
        ((null? clauses) (error "find-begin-clause: no (begin ...) clause found"))
        ((and (pair? (car clauses)) (eq? (caar clauses) 'begin)) (car clauses))
        (else (find-begin-clause (cdr clauses)))))

    (define (library-body-source path)
      (let* ((top (read (open-input-string (file-read path))))
             (clauses (cddr top)) ; drop 'define-library and the (creme name) library-name clause
             (begin-clause (find-begin-clause clauses)))
        (string-join (map write-to-string (cdr begin-clause)) "\n")))))
