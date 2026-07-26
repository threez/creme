;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/modules/creme/bootstrap_spec.cr's
;; own cases exercising (creme bootstrap)'s import!/expand-if-macro
;; primitives directly -- see modules/creme/spec.sld's own header comment
;; for the framework this uses. These are asserted against literal
;; expected values (should-equal?), not should-match-native?, since
;; they're testing the primitives themselves, not comparing two
;; compilers' output.
;;
;; Skipped from the original file: "runs a deserialized chunk that
;; matches direct evaluation", "round-trips closures, recursion, and
;; strings/vectors", and "raises a clean error on garbage bytes" -- all
;; three are already thoroughly exercised (load-chunk-bytes/compile-
;; source-to-bytes on all kinds of values) by every should-match-native?
;; case across every other spec/creme/*.scm file.
;;
;; Run with:
;;   ./bin/creme spec/creme/bootstrap_spec.scm                    (all 5 pass)
;;   ./bin/creme --self-hosted spec/creme/bootstrap_spec.scm       (4 of 5)
;;   ./cvm/cvm spec/creme/bootstrap_spec.scm                       (3 of 5)
;; --self-hosted fails only "import! copies a library's bindings into the
;; global env" (see its own comment -- a harmless environment artifact,
;; not a bug). `cvm/cvm` passes that same case's own sibling ("expand-
;; if-macro detects and expands a define-syntax-defined global" -- see
;; this file's own comment on my-swap! below, now fixed) but still fails:
;;   - "import! copies a library's bindings into the global env" -- same
;;     environment-artifact reasoning as --self-hosted (cvm/compiler-run.
;;     scm's own toolchain also transitively imports (creme regex)).
;;   - "import! applies only/except/prefix import-set filters" -- cvm's
;;     own import! (cvm/bootstrap.c) is a PERMANENT no-op at the
;;     PROCEDURE level. Bridging this out to compiler.sld's own alias-
;;     generation logic (the same pattern expand-if-macro's own bridging
;;     below uses) was tried and reverted: compile-import!'s own runtime-
;;     emitted payload calls `import!` BEFORE `ensure-libraries-loaded!`
;;     in the same sequence, so a bridge triggered directly from import!
;;     itself fires too early -- before the target library's own exports
;;     are even defined -- raising "unbound variable" for names compile-
;;     import!'s own LATER, correctly-ordered alias-defines-for-specs
;;     forms resolve fine on their own. A real fix needs a different hook
;;     point than import! itself; left as a known gap rather than risking
;;     that regression (confirmed: it broke compiler_libraries_spec.scm's
;;     own prefix-import case, which does NOT call import! directly and
;;     was completely unaffected by this bug until then).
;; ===========================================================================

;; Deliberately NOT (import (creme regex)) here -- the first two cases
;; check that regexp-matches?/rx-regexp are genuinely unbound before
;; import! brings them in dynamically at runtime; a static top-level
;; import of (creme regex) would make that check meaningless. The FIRST
;; case's own initial check fails regardless under BOTH --self-hosted
;; and cvm/cvm: each has its own bootstrap toolchain (SELF_HOSTED_
;; TOOLCHAIN_IMPORT in src/main.cr for --self-hosted; cvm/compiler-run.
;; scm's own top-level import clause for cvm) that already transitively
;; imports (creme regex) for the compiler's own use, so regexp-matches?
;; is bound before this script even starts -- an environment difference
;; between how each of these bootstraps itself, not a compiler bug.
(import (scheme base) (scheme write) (scheme process-context)
        (creme bootstrap) (creme spec))

(define (write-to-string v)
  (let ((port (open-output-string)))
    (write v port)
    (get-output-string port)))

;; Registered at this file's own TRUE top level, not inside an `it` block
;; -- (creme spec)'s it/describe both wrap their body in a lambda, and a
;; defmacro/define-syntax registered INSIDE a lambda body is an INTERNAL
;; one, scoped to that lambda's own local frame; it never becomes a real,
;; globally-visible binding the way a genuinely top-level one does (see
;; expand-if-macro's own contract: it looks up a NAME in the true global
;; table). Confirmed empirically: nesting these inside their own `it`
;; block made expand-if-macro see nothing (#f) even under native
;; evaluation, for exactly this reason.
;;
;; This also originally surfaced a genuinely self-hosted-only gap (now
;; fixed, modules/creme/compiler/compiler.sld): under native Crystal
;; compilation, EVEN a top-level defmacro/define-syntax registers a real
;; runtime value in the global env (bytecode_compiler.cr emits
;; Op::HelperForm kind 3/4 for DefineSyntax/Defmacro, run at bytecode-
;; execution time via eval_define_syntax/eval_defmacro) -- but the self-
;; hosted compiler's own compile-defmacro!/compile-define-syntax! used to
;; ONLY EVER register into their own compile-time-only macro-table,
;; emitting no bytecode that would define an equivalent runtime value.
;; Fixed by having both ALSO emit the same Op::HelperForm kind 3/4 the
;; native compiler does, but ONLY at the true top level (fcomp-at-
;; toplevel?, compiler.sld) -- an INTERNAL one must NOT get a permanent
;; runtime global binding, or it would leak past its own lexical scope
;; the same way compile-scoped-body!'s own earlier fix was needed for.
;;
;; Under cvm/cvm specifically, this ALSO now works for both defmacro AND
;; define-syntax: cvm's OWN VM (cvm/vm.c's Op::HelperForm) binds a real
;; T_MACRO value for kind 3 (define-syntax) the same way it already did
;; for kind 4 (defmacro), and bi_expand_if_macro (cvm/bootstrap.c) picks
;; the right bridge (defmacro-expand-form vs. the new define-syntax-
;; expand-form, compiler.sld -- built on the self-hosted compiler's own
;; sr-make-transformer, its real syntax-rules pattern matcher, already
;; loaded for exactly this purpose) by checking the wrapped form's own
;; head symbol. cvm's C VM still never expands a syntax-rules use
;; DIRECTLY (no pattern-matching machinery in C) -- it bridges out to
;; Scheme for that, same as it always did for defmacro.
(defmacro my-list2 args (cons 'list args))
(define-syntax my-swap! (syntax-rules () ((_ a b) (let ((tmp a)) (set! a b) (set! b tmp)))))

(describe "(creme bootstrap)'s import!/expand-if-macro primitives"
  (it "import! copies a library's bindings into the global env"
    (should-raise? (lambda () regexp-matches?))
    (import! '((creme regex)))
    (should-be-true? (regexp-matches? (regexp "a+") "aaa")))

  (it "import! applies only/except/prefix import-set filters"
    (import! '((prefix (only (creme regex) regexp) filter-test-rx-)))
    (should-be-true? (procedure? filter-test-rx-regexp)))

  (it "expand-if-macro detects and expands a defmacro-defined global"
    (should-equal? (write-to-string (expand-if-macro '(my-list2 1 2 3))) "(#t list 1 2 3)"))

  (it "expand-if-macro detects and expands a define-syntax-defined global"
    (should-equal?
      (write-to-string (expand-if-macro '(my-swap! x y)))
      "(#t let ((tmp x)) (set! x y) (set! y tmp))"))

  (it "expand-if-macro returns #f for an ordinary procedure or unbound name"
    (should-equal? (write-to-string (expand-if-macro '(+ 1 2))) "#f")
    (should-equal? (write-to-string (expand-if-macro '(totally-unbound-name 1 2))) "#f")))

(spec-summary!)
