;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/r7rs/ch06_12_environments_eval_
;; spec.cr's own cases -- see modules/creme/spec.sld's own header comment
;; for the framework this uses. The original Crystal spec evaluated each
;; case's Scheme source via a fresh sub-interpreter (run(src)/w(src)) since
;; it was testing a Scheme interpreter from OUTSIDE, as Crystal code; here,
;; running directly as Scheme, each case's forms are written and asserted
;; directly via should-equal?/should-raise? instead of comparing
;; write_string'd output against a literal string.
;;
;; See also spec/creme/environments_spec.scm, an existing narrower port of
;; this same Crystal file that used to deliberately exclude every
;; isolation-dependent case (see its own header comment) because of a
;; genuine cvm gap: `environment` was entirely unbound under cvm/cvm, and
;; `interaction-environment`/`scheme-report-environment`/`null-
;; environment` were non-isolating stubs (`eval` ignored its own
;; environment argument entirely, evaluating everything against the one
;; real global table regardless of what was passed).
;;
;; All of that is now fixed: `environment`/`null-environment` are backed
;; by a genuinely separate child VM per environment
;; (cvm_new_empty_vm/BOX_KIND_ENVIRONMENT, cvm/vm.c and cvm/vm.h's own
;; doc comments) with its own independent global table, populated (for
;; `environment`) by copying exactly the requested import-set's own
;; resolved bindings (modules/creme/compiler/compiler.sld's new
;; import-set-resolved-bindings, reusing library-export-alist) out of the
;; calling environment; `eval`'s 2-arg form loads and runs the compiled
;; form against THAT target environment's own table
;; (load-chunk-bytes-into, cvm/bootstrap.c) instead of always the current
;; one. `scheme-report-environment`/`interaction-environment` mirror
;; native's own deliberate non-isolation for those two specifically
;; (wrapping the CURRENT running VM directly, not a fresh one -- see
;; r5rs.cr's own comment on why). So every case in this file now runs
;; unconditionally, matching native/--self-hosted exactly.
;;
;; Run with (all cases pass, 0 pending, under all three):
;;   ./bin/creme spec/creme/r7rs/ch06_12_environments_eval_spec.scm
;;   ./bin/creme --self-hosted spec/creme/r7rs/ch06_12_environments_eval_spec.scm
;;   ./cvm/cvm spec/creme/r7rs/ch06_12_environments_eval_spec.scm
;; ===========================================================================

(import (scheme base) (scheme eval) (scheme r5rs) (scheme repl) (creme spec))

;; interaction-environment specifically means the REAL global environment
;; (@global, per src/creme/modules/scheme/repl.cr's own comment) -- unlike
;; every other top-level define in this file (deliberately avoided so
;; test-local names can't collide across `it`s in this one shared
;; process), this one genuinely has to be a top-level define: an internal
;; define inside an `it`'s own (lambda () ...) body would only bind `x`
;; in THAT lambda's local frame, never in the actual global environment
;; interaction-environment hands back, defeating the point of the case.
(define x 42)

(describe "R7RS §6.12 Environments and evaluation"
  (it "environment returns a specifier for an environment built by importing the given import sets"
    (should-equal? (eval '(* 7 3) (environment '(scheme base))) 21))

  (it "environment's import sets support the only/except/prefix/rename combinators"
    (should-equal? (eval '(+ 10) (environment '(only (scheme base) +))) 10))

  (it "scheme-report-environment returns a specifier for an environment with the R5RS-report bindings"
    (should-equal? (eval '(* 2 3) (scheme-report-environment 5)) 6))

  (it "null-environment returns a specifier for an environment with only syntax, no procedures"
    (eval '(lambda (f x) (f x x)) (null-environment 5))
    (should-be-true? #t)
    (should-raise? (lambda () (eval '+ (null-environment 5)))))

  (it "interaction-environment returns a specifier for the environment a REPL would evaluate typed-in expressions against"
    (should-equal? (eval 'x (interaction-environment)) 42))

  (it "eval (single-argument form, always evaluating against the global environment) works"
    (should-equal? (eval '(* 7 3)) 21))

  (it "eval's two-argument form evaluates expr-or-def in the specified environment"
    (let ((f (eval '(lambda (f x) (f x x)) (environment '(scheme base)))))
      (should-equal? (f + 10) 20))))

(spec-summary!)
