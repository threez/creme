;; ===========================================================================
;; A (creme spec)-based sample of testing the SELF-HOSTED compiler
;; (modules/creme/compiler/{reader,compiler}.sld) from Scheme itself --
;; see modules/creme/spec.sld's own header comment for the framework this
;; uses, and spec/scheme/modules/creme/compiler/compiler_spec.cr for this
;; same native-vs-bootstrap comparison written the OTHER way, as a Crystal
;; spec driving the Crystal interpreter directly. This file exercises the
;; identical idea -- compile a snippet with the self-hosted compiler, run
;; it, and check it matches plain native evaluation of the same snippet --
;; but entirely as a running Scheme program, with no Crystal spec process
;; involved: a real demonstration that (creme spec) is enough to write
;; compiler regression tests without leaving Scheme.
;;
;; Run with:
;;   ./bin/creme spec/creme/compiler_spec.scm            (native Crystal VM)
;;   ./bin/creme --self-hosted spec/creme/compiler_spec.scm
;; (not yet `--cvm`: describe/it are syntax-rules macros -- see (creme
;; spec)'s own header comment on why that specific combination doesn't
;; work yet.)
;; ===========================================================================

(import (scheme base) (scheme write) (scheme read) (scheme process-context) (scheme eval)
        (scheme lazy) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec))

;; Reads every top-level form out of `src` and evaluates them in order,
;; returning the LAST form's value -- same "whole program, last value"
;; contract compile-source-to-bytes's own compiled chunk has, so this is
;; a fair comparison against bootstrap-eval below.
(define (native-eval src)
  (let ((in (open-input-string src)))
    (let loop ((result (if #f #f)))
      (let ((form (read in)))
        (if (eof-object? form)
            result
            (loop (eval form)))))))

(define (bootstrap-eval src)
  (load-chunk-bytes (compile-source-to-bytes src)))

(define (write-to-string v)
  (let ((port (open-output-string)))
    (write v port)
    (get-output-string port)))

;; Compares the self-hosted compiler's own output against plain native
;; evaluation of the SAME source, via each side's printed representation
;; (write-to-string) rather than `equal?` directly -- matches compiler_
;; spec.cr's own `.write_string` comparison, robust to values (like
;; records) that `equal?` doesn't necessarily consider interchangeable
;; even when they should print identically for this test's purposes.
(define (should-match-native? src)
  (should-equal? (write-to-string (bootstrap-eval src)) (write-to-string (native-eval src))))

(describe "self-hosted compiler matches native evaluation"
  (it "adds numbers" (should-match-native? "(+ 1 2 3)"))
  (it "evaluates a conditional" (should-match-native? "(if (> 3 2) 'yes 'no)"))
  (it "defines and calls a recursive function"
    (should-match-native? "(define (fact n) (if (= n 0) 1 (* n (fact (- n 1))))) (fact 10)"))
  (it "closes over an outer variable"
    (should-match-native? "(define (make-adder n) (lambda (x) (+ x n))) ((make-adder 5) 10)"))
  (it "a bare top-level (define ...) evaluates to the defined name"
    (should-match-native? "(define x 42)"))
  (it "case with a hashable-datum dispatch"
    (should-match-native? "(define (classify n) (case n ((1 2 3) 'small) ((4 5 6) 'medium) (else 'large))) (list (classify 2) (classify 5) (classify 99))"))

  (describe "records"
    (it "define-record-type produces a real record, not a vector"
      (should-match-native? "(define-record-type <point> (make-point x y) point? (x point-x) (y point-y)) (define p (make-point 3 4)) (list (vector? p) (point? p) (point-x p) (point-y p))"))))

(spec-summary!)
