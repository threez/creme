;; ===========================================================================
;; A (creme spec)-based port of the non-isolation-dependent half of
;; spec/scheme/r7rs/ch06_12_environments_eval_spec.cr's own cases -- see
;; modules/creme/spec.sld's own header comment for the framework this
;; uses, and compiler_spec.scm's own header comment for the general
;; should-match-native? approach.
;;
;; interaction-environment/scheme-report-environment/null-environment and
;; eval's optional 2nd (environment specifier) argument USED to be a
;; deliberate icecreme gap -- icecreme/compiler-run.scm's own versions of these were
;; non-isolating stubs, since icecreme has exactly ONE flat global table. Now
;; fixed for real (a genuinely separate child VM per environment -- see
;; icecreme/README.md's own "environment/eval" section and icecreme/vm.c's
;; cvm_new_empty_vm), so every isolation-dependent case this file used to
;; exclude now has FULL, unweakened coverage in
;; spec/creme/r7rs/ch06_12_environments_eval_spec.scm instead (including
;; "null-environment ... has only syntax, no procedures" and "environment's
;; import sets support only/except/prefix/rename"). This file is now
;; redundant with that one but kept as-is (a narrower, still-valid subset)
;; rather than deleted.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/environments_spec.scm
;;   ./bin/creme --self-hosted spec/creme/environments_spec.scm
;;   ./icecreme/icecreme spec/creme/environments_spec.scm
;; ===========================================================================

;; See compiler_spec.scm's own comment on why the full toolchain import
;; list is still needed here even though (creme compiler spec-helper)
;; already imports all of it for itself.
(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme repl) (scheme r5rs) (scheme lazy) (creme peg) (creme regex) (creme bytecode)
        (creme bootstrap) (creme compiler reader) (creme compiler compiler)
        (creme spec) (creme compiler spec-helper))

(describe "environments and evaluation"
  (it "eval (single-argument form) evaluates against the global environment"
    (should-match-native? '((eval '(* 7 3)))))

  (it "interaction-environment returns a specifier eval accepts, evaluating against the global environment"
    (should-match-native? '((define x 42) (eval 'x (interaction-environment)))))

  (it "scheme-report-environment returns a specifier eval accepts"
    (should-match-native? '((eval '(* 2 3) (scheme-report-environment 5)))))

  (it "null-environment returns a specifier eval accepts for syntax-only forms"
    (should-match-native? '((eval '(lambda (f x) (f x x)) (null-environment 5)) 'ok))))

(spec-summary!)
