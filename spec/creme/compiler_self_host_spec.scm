;; ===========================================================================
;; A (creme spec)-based port of compiler_spec.cr's self-hosting cases -- the
;; self-hosted compiler compiling ITS OWN SOURCE (reader.sld, then
;; compiler.sld) and the result still working correctly -- plus the one
;; case that intentionally does NOT compare against native evaluation (a
;; register-safety edge case where the two deliberately diverge). See
;; modules/creme/spec.sld's own header comment for the framework this
;; uses, and compiler_spec.scm's own header comment for the general
;; should-match-native? approach used elsewhere in this project.
;;
;; Run with:
;;   ./bin/creme spec/creme/compiler_self_host_spec.scm
;;   ./bin/creme --self-hosted spec/creme/compiler_self_host_spec.scm
;; ===========================================================================

(import (scheme base) (scheme write) (scheme read) (scheme process-context) (scheme eval)
        (scheme lazy) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme file) (creme string) (creme spec))

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

;; Every top-level form in `src`, read by the NATIVE (Crystal) reader --
;; used as the "native" side of the read-program self-compile test below,
;; since `read` (scheme read) always goes through the native reader
;; regardless of which compiler is active.
(define (read-all-native src)
  (let ((in (open-input-string src)))
    (let loop ((acc '()))
      (let ((form (read in)))
        (if (eof-object? form)
            (reverse acc)
            (loop (cons form acc)))))))

;; Extracts the (begin form1 form2 ...) clause's own forms out of a
;; (define-library (creme name) (export ...) (import ...) (begin ...))
;; file, re-printed as source text (one form per line) -- the self-compile
;; tests below need these AS SOURCE TEXT, since compile-source-to-bytes
;; compiles a flat sequence of top-level forms, not a define-library
;; wrapper.
(define (find-begin-clause clauses)
  (cond
    ((null? clauses) (error "find-begin-clause: no (begin ...) clause found"))
    ((and (pair? (car clauses)) (eq? (caar clauses) 'begin)) (car clauses))
    (else (find-begin-clause (cdr clauses)))))

(define (library-body-source path)
  (let* ((top (read (open-input-string (file-read path))))
         (clauses (cddr top)) ; drop 'define-library and the (creme name) library-name clause
         (begin-clause (find-begin-clause clauses)))
    (string-join (map write-to-string (cdr begin-clause)) "\n")))

;; The critical new safety case: a closure capturing a let-bound local,
;; called AFTER several more sibling scopes have run and popped -- must
;; still see the value at capture time, not whatever a later sibling
;; scope's own local happens to reuse that register for. This is exactly
;; the pattern the real Crystal BytecodeCompiler gets WRONG (verified
;; empirically there: native evaluation returns 2, the last sibling
;; scope's own value, instead of 42 -- pop_scope rolls next_reg back
;; unconditionally, never consulting captured_registers, and upvalues are
;; only closed at frame-return/tail-call time, never at ordinary lexical
;; scope exit) -- so unlike every other case in this project's spec
;; files, this asserts the bootstrap-compiled result directly against the
;; CORRECT value, not against (a knowingly wrong) native evaluation.
;;
;; Must run BEFORE the self-hosting describe block below: that block
;; permanently replaces the global compile-source-to-bytes/read-program
;; with the SELF-COMPILED versions (load-chunk-bytes always writes into
;; this one shared process's global table, same reasoning as compiler_
;; defmacro_spec.scm's own note on the +/car redefinition tests) -- and
;; the self-compiled compiler, run this reentrantly deep, doesn't (yet)
;; carry over every native builtin its own macro-expansion path reaches
;; (confirmed empirically: running this AFTER self-hosting replaced
;; compile-source-to-bytes raised "unbound variable: char-downcase" from
;; deep inside compiling this test's own source -- unrelated to the
;; register-safety property this test actually checks).
(describe "register safety (an edge case where bootstrap intentionally differs from native)"
  (it "protects a captured local's register across later sibling scopes"
    (should-equal?
      (write-to-string
        (load-chunk-bytes
          (compile-source-to-bytes
            "(define (h) (define snap #f) (let ((x 42)) (set! snap (lambda () x))) (let ((y 1)) (set! y (+ y 1))) (let ((z 2)) (set! z (* z 2))) (let ((w 3)) (set! w (- w 1))) (snap)) (h)")))
      "42")))

(describe "self-hosting: the compiler compiles its own source"
  (it "self-compiles (creme compiler reader) and produces a working read-program"
    (let* ((body-source (library-body-source "modules/creme/compiler/reader.sld")))
      (load-chunk-bytes (compile-source-to-bytes body-source))
      ;; read-program is now the SELF-COMPILED version's own definition.
      (let* ((test-source "(define (fact n) (if (= n 0) 1 (* n (fact (- n 1))))) (display (fact 5)) (newline) (define v #(1 2 3)) (write v)")
             (forms (read-program test-source))
             (out (open-output-string)))
        (for-each (lambda (f) (write f out) (write-char #\newline out)) forms)
        (should-equal? (get-output-string out)
                       (string-append (string-join (map write-to-string (read-all-native test-source)) "\n") "\n")))))

  (it "self-compiles (creme compiler compiler) and the result compiles a small program correctly"
    (let ((body-source (library-body-source "modules/creme/compiler/compiler.sld")))
      (load-chunk-bytes (compile-source-to-bytes body-source))
      ;; compile-source-to-bytes is now the SELF-COMPILED version's own
      ;; definition -- use it to compile a small program, same
      ;; should-match-native? comparison as everywhere else.
      (let ((test-source "(define (fact n) (if (= n 0) 1 (* n (fact (- n 1))))) (fact 6)"))
        (should-equal? (write-to-string (load-chunk-bytes (compile-source-to-bytes test-source)))
                       (write-to-string (native-eval test-source)))))))

(spec-summary!)
