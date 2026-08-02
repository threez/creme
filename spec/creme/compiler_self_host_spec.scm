;; ===========================================================================
;; A (creme spec)-based port of compiler_spec.cr's self-hosting cases -- the
;; self-hosted compiler compiling ITS OWN SOURCE (reader.sld, then
;; compiler.sld) and the result still working correctly -- plus a register-
;; safety case (see below). See modules/creme/spec.sld's own header comment
;; for the framework this uses, and compiler_spec.scm's own header comment
;; for the general should-match-native? approach used elsewhere in this
;; project.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/compiler_self_host_spec.scm
;;   ./bin/creme --self-hosted spec/creme/compiler_self_host_spec.scm
;;   ./icecreme/icecreme spec/creme/compiler_self_host_spec.scm
;; ===========================================================================

;; See compiler_spec.scm's own comment on why the full toolchain import
;; list is still needed here even though (creme compiler spec-helper)
;; already imports all of it for itself.
(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme file) (creme string)
        (creme spec) (creme compiler spec-helper))

;; A closure capturing a let-bound local, called AFTER several more
;; sibling scopes have run and popped, must still see the value at
;; capture time, not whatever a later sibling scope's own local happens
;; to reuse that register for. This USED to be a genuine bug in the real
;; Crystal BytecodeCompiler too (native evaluation returned 2, the last
;; sibling scope's own value, instead of 42 -- pop_scope rolled next_reg
;; back unconditionally, never consulting captured_registers, and
;; upvalues are only closed at frame-return/tail-call time, never at
;; ordinary lexical scope exit) -- now fixed there too, generally
;; (applied at every scope exit/mid-scope reclaim, which also required
;; fixing compile_app's two general-path branches to reserve every call
;; argument's register up front -- see bytecode_compiler.cr's own
;; comments), see spec/scheme/compile/bytecode_vm_spec.cr's own
;; "protects a captured local's register"/"keeps later call arguments
;; in their own registers" cases, which exercise BytecodeCompiler
;; directly and are the real regression tests for these fixes. This
;; case here only ever tested the self-hosted compiler's own,
;; independent implementation, which never had either bug -- hence
;; still asserting against a hardcoded "42",
;; not should-match-native?, since should-match-native? would only ever
;; have compared two implementations that already agreed.
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
(describe "register safety (the self-hosted compiler's own implementation)"
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
