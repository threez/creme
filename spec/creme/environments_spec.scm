;; ===========================================================================
;; A (creme spec)-based port of the non-isolation-dependent half of
;; spec/scheme/r7rs/ch06_12_environments_eval_spec.cr's own cases -- see
;; modules/creme/spec.sld's own header comment for the framework this
;; uses, and compiler_spec.scm's own header comment for the general
;; should-match-native? approach.
;;
;; interaction-environment/scheme-report-environment/null-environment and
;; eval's optional 2nd (environment specifier) argument used to be a
;; deliberate cvm gap -- cvm has exactly ONE flat global table (vm->globals
;; in vm.c/vm.h), so cvm/compiler-run.scm's own interaction-environment/
;; scheme-report-environment/null-environment are DELIBERATE STUBS (see
;; that file's own comment): they return a plain symbol satisfying eval's
;; calling convention, but eval itself ignores whatever environment
;; specifier it's given and always evaluates against the one real global
;; table -- there is no isolation to honor either way.
;;
;; Because of that stub, this file deliberately does NOT port every case
;; from ch06_12_environments_eval_spec.cr -- specifically excluded:
;;   - "null-environment ... has only syntax, no procedures" (its OWN
;;     `+`-is-unbound-there assertion requires real isolation cvm's stub
;;     can't provide)
;;   - "environment's import sets support only/except/prefix/rename" and
;;     the general (environment '(scheme base))-as-a-real-restricted-
;;     import-set case (same reason -- (environment ...) itself isn't
;;     implemented in cvm at all, since a non-isolating stub would be
;;     actively misleading rather than simply absent)
;; Every case actually included here only checks that eval/interaction-
;; environment/scheme-report-environment/null-environment exist, accept
;; the right arity, and evaluate correctly against the (only) global
;; table -- exactly what cvm's stub can honestly provide.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/environments_spec.scm
;;   ./bin/creme --self-hosted spec/creme/environments_spec.scm
;;   ./cvm/cvm spec/creme/environments_spec.scm
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
