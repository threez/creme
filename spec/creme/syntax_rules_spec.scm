;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/compile/syntax_rules_spec.cr's
;; own cases -- define-syntax/syntax-rules semantics not already covered
;; by compiler_spec.scm's own "define-syntax / syntax-rules macros"
;; section (basic ellipsis matching, literal keywords, recursive
;; expansion, an internal define-syntax scoped to a lambda body, and the
;; hygiene cases: binder renaming, and a macro's own use of a special
;; form/another macro surviving use-site shadowing) -- see modules/creme/
;; spec.sld's own header comment for the framework this uses, and
;; compiler_spec.scm's own header comment for the general should-match-
;; native?/should-raise? approach (source is a quoted list of forms, not
;; a string).
;;
;; NOT covered here (deliberately, since it would diverge between native
;; and self-hosted/icecreme, breaking should-match-native?): a macro's own
;; free reference to an ORDINARY GLOBAL PROCEDURE surviving use-site
;; shadowing. Native protects this (it can check its own captured
;; definition environment); the self-hosted/icecreme compiler cannot (no
;; compile-time global-binding registry exists there — seen. compiler.sld's
;; own sr-apply-hygiene header comment for the real regression this
;; narrowed scope was found fixing). Also NOT covered: a macro's free
;; reference to an ENCLOSING LEXICAL LOCAL (the one honestly-unresolved
;; hygiene gap on both backends — see README Known caveats and
;; spec/creme/r7rs/ch04_expressions_spec.scm's own let-syntax case).
;;
;; The three cases in the original file asserting an exact Crystal error-
;; message substring (`/no matching syntax-rules clause/`, `/define-
;; syntax: malformed/`, `/define-syntax: expected syntax-rules/`) are
;; ported as plain should-raise? with no message check -- the self-hosted
;; compiler's own error text isn't guaranteed to match Crystal's verbatim,
;; only that it also rejects each case.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/syntax_rules_spec.scm
;;   ./bin/creme --self-hosted spec/creme/syntax_rules_spec.scm
;;   ./icecreme/icecreme spec/creme/syntax_rules_spec.scm
;; ===========================================================================

;; See compiler_spec.scm's own comment on why the full toolchain import
;; list is still needed here even though (creme compiler spec-helper)
;; already imports all of it for itself.
(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(describe "define-syntax/syntax-rules matches native evaluation"
  (it "expands a basic macro with no literals or ellipsis"
    (should-match-native?
      '((define-syntax my-if (syntax-rules () ((_ c t e) (cond (c t) (else e)))))
        (list (my-if #t 1 2) (my-if #f 1 2)))))

  (it "supports ellipsis in both pattern and template"
    (should-match-native?
      '((define-syntax my-list (syntax-rules () ((_ x ...) (list x ...))))
        (my-list 1 2 3))))

  (it "supports an empty ellipsis match"
    (should-match-native?
      '((define-syntax my-list (syntax-rules () ((_ x ...) (list x ...))))
        (my-list))))

  (it "matches a literal keyword and rejects a non-matching one"
    (should-match-native?
      '((define-syntax my-cond
          (syntax-rules (else)
            ((_ (else e ...)) (begin e ...))
            ((_ (c e ...) rest ...) (if c (begin e ...) (my-cond rest ...)))))
        (my-cond (#f 1) (#t 2) (else 3)))))

  (it "dispatches to different templates via multiple pattern clauses (recursive expansion)"
    (should-match-native?
      '((define-syntax my-let*
          (syntax-rules ()
            ((_ () body ...) (begin body ...))
            ((_ ((var val) rest ...) body ...)
             (let ((var val)) (my-let* (rest ...) body ...)))))
        (my-let* ((a 1) (b (+ a 1))) (* a b)))))

  (it "supports fixed args mixed with a trailing ellipsis"
    (should-match-native?
      '((define-syntax my-begin (syntax-rules () ((_ first rest ...) (begin first rest ...))))
        (my-begin 1 2 3))))

  (it "works as a local macro definition scoped to a lambda body (internal define-syntax)"
    (should-match-native?
      '((define (f)
          (define-syntax double (syntax-rules () ((_ x) (* 2 x))))
          (double 21))
        (f))))

  ;; This project's macro system is HYGIENIC (both compilers, see
  ;; syntax_rules.cr's own header comment for the design) -- a template-
  ;; introduced identifier is alpha-renamed to a fresh, process-unique
  ;; name, so it can no longer capture (or be captured by) a use-site
  ;; binding of the same name. swap!'s own `tmp` binding no longer
  ;; shadows the use-site `tmp` passed as the `a` argument, so the swap
  ;; correctly threads the original values through: (2 1), not the
  ;; pre-hygiene capture bug's (1 2). should-match-native? confirms both
  ;; compilers agree.
  (it "is hygienic: a template-introduced identifier cannot capture a use-site binding of the same name"
    (should-match-native?
      '((define-syntax swap! (syntax-rules () ((_ a b) (let ((tmp a)) (set! a b) (set! b tmp)))))
        (define tmp 1)
        (define y 2)
        (swap! tmp y)
        (list tmp y))))

  ;; A macro's own use of a special form can never be hijacked by a
  ;; use-site local of the same name — true on BOTH backends, though for
  ;; different reasons: native's analyzer explicitly protects it (see
  ;; SchemeSym#forced_free_ref); the self-hosted/icecreme compiler's own
  ;; compile-form! dispatches special forms by a fixed literal comparison
  ;; that never consults lexical scope at all, so it was already immune.
  (it "is hygienic: a macro's own use of a special form can't be hijacked by a use-site local of the same name"
    (should-match-native?
      '((define-syntax my-if (syntax-rules () ((_ c t e) (if c t e))))
        (let ((if (lambda (a b c) 'shadowed))) (my-if #t 'yes 'no)))))

  ;; A macro's own reference to ANOTHER macro can't be hijacked by a
  ;; use-site local of the same name either (both backends — see
  ;; syntax-global-alias/macro-lookup's own header comment for how the
  ;; self-hosted/icecreme side protects this specific, always-safe case).
  (it "is hygienic: a macro's own reference to another macro can't be hijacked by a use-site local of the same name"
    (should-match-native?
      '((define-syntax inner-answer (syntax-rules () ((_) 42)))
        (define-syntax outer-answer (syntax-rules () ((_) (inner-answer))))
        (let ((inner-answer (lambda () 'shadowed))) (outer-answer)))))

  (it "raises when no rule matches"
    (should-raise?
      (lambda ()
        (bootstrap-eval-forms
          '((define-syntax only-one (syntax-rules () ((_ a b) (+ a b)))) (only-one 1))))))

  (it "raises on malformed input"
    (should-raise? (lambda () (bootstrap-eval-forms '((define-syntax bad))))))

  (it "raises when the syntax-rules keyword is missing"
    (should-raise?
      (lambda ()
        (bootstrap-eval-forms '((define-syntax bad (not-syntax-rules () ((_ a) a)))))))))

(spec-summary!)
