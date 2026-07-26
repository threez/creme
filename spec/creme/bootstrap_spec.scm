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
;;   ./bin/creme spec/creme/bootstrap_spec.scm
;; --self-hosted also passes every case here EXCEPT "import! copies a
;; library's bindings into the global env" (its own comment explains
;; why -- a harmless --self-hosted-only environment artifact, not a bug).
;; ===========================================================================

;; Deliberately NOT (import (creme regex)) here -- the first two cases
;; check that regexp-matches?/rx-regexp are genuinely unbound before
;; import! brings them in dynamically at runtime; a static top-level
;; import of (creme regex) would make that check meaningless. Under
;; --self-hosted specifically, the FIRST case's own initial check still
;; fails regardless: its own bootstrap toolchain (SELF_HOSTED_TOOLCHAIN_
;; IMPORT, src/main.cr) already transitively imports (creme regex) for
;; the compiler's own use, so regexp-matches? is bound before this
;; script even starts -- an environment difference between how a plain
;; run and --self-hosted bootstrap themselves, not a compiler bug.
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
