;; ===========================================================================
;; (creme ir): generic S-expression code-generation building blocks
;;
;; A domain-agnostic toolkit for the "staging"/Futamura-projection trick
;; (creme sql-compile) uses: instead of interpreting a tree at run time,
;; GENERATE a Scheme S-expression specialized to one input, hand it to `eval`
;; once (see (scheme eval)), and get back a real BytecodeClosure -- calling
;; it afterward is an ordinary already-compiled procedure call, no
;; re-parsing or re-interpretation of anything.
;;
;; This module knows nothing about SQL, operator trees, or any other
;; specific domain -- only about building valid Scheme code AS DATA. Every
;; gen-* procedure here runs AT CODEGEN TIME (never appears in, and costs
;; nothing at, run time) and returns a quoted-looking S-expression, not a
;; value: (gen-if 'x 1 2) => (if x 1 2), a 3-element list, not the number 1
;; or 2. None of these procedures ever call `eval` themselves -- assembling
;; and evaluating generated code is entirely the caller's responsibility.
;;
;; Covers this project's whole run-time-relevant special-form catalog (see
;; "Special forms" list): quote, if, cond, when, unless, define,
;; set!, lambda, let/let*/letrec/named-let, do, case, and, or, begin. Every
;; ordinary procedure call (vector-ref, hash-table-set!, csv-reader-read!,
;; ...) is instead covered generically by gen-call, since a plain
;; application is just `(cons proc-sym args)` -- it doesn't need its own
;; dedicated builder. gen-vector-ref/gen-vector-set! exist anyway as named
;; convenience wrappers, since (creme sql-compile) leans on them heavily.
;;
;; Deliberately NOT covered: define-syntax/syntax-rules/defmacro (macro
;; expansion is a source-level, analyze-time concern -- a generated-and-eval'd
;; lambda body is already fully expanded by construction), guard/
;; parameterize/dynamic-wind (VM-level dynamic-extent bookkeeping, not
;; something a specialized query body needs to introduce itself),
;; define-record-type/define-library/import (module-system forms, not
;; expressions), case-lambda/cond-expand/let-values/let*-values (not needed
;; by any current generator; add a builder here if a future one does).
;; ===========================================================================

(define-library (creme ir)
  (export filter map-indexed gensym-var
          gen-quote gen-call gen-value-list gen-cons gen-vector
          gen-vector-ref gen-vector-set!
          gen-let gen-let* gen-letrec gen-named-let gen-lambda gen-define
          gen-if gen-when gen-unless gen-cond gen-case gen-and gen-or
          gen-begin gen-do gen-set!)
  ;; filter/map-indexed are genuine (creme extra) exports (not redefined
  ;; here) -- re-exported directly so a caller that only needs (creme ir)
  ;; doesn't also have to import (creme extra) itself, the same pattern
  ;; (creme prof)'s own header comment documents for combining libraries.
  (import (scheme base) (creme introspection) (creme extra))
  (begin
    ;; A fresh codegen-time variable name, prefixed for readability if the
    ;; generated code is ever inspected/printed.
    (define (gensym-var prefix) (gensym prefix))

    ;; ---- data / application --------------------------------------------

    (define (gen-quote value) (list 'quote value))
    (define (gen-call proc-sym . args) (cons proc-sym args))
    (define (gen-value-list exprs) (cons 'list exprs))
    (define (gen-cons a b) (list 'cons a b))
    (define (gen-vector exprs) (cons 'vector exprs))
    (define (gen-vector-ref vec-expr idx) (list 'vector-ref vec-expr idx))
    (define (gen-vector-set! vec-expr idx val-expr) (list 'vector-set! vec-expr idx val-expr))

    ;; ---- binding forms ---------------------------------------------------
    ;;
    ;; `bindings` is a list of (var expr) pairs, e.g. (list (list 'x 1)); a
    ;; procedure taking `body ...` (variadic) builds a form with more than
    ;; one body expression, matching every R7RS binding/lambda form's own
    ;; implicit `begin`.

    (define (gen-let bindings . body) (cons 'let (cons (map (lambda (b) (list (car b) (cadr b))) bindings) body)))
    (define (gen-let* bindings . body) (cons 'let* (cons (map (lambda (b) (list (car b) (cadr b))) bindings) body)))
    (define (gen-letrec bindings . body) (cons 'letrec (cons (map (lambda (b) (list (car b) (cadr b))) bindings) body)))
    (define (gen-named-let name bindings . body)
      (cons 'let (cons name (cons (map (lambda (b) (list (car b) (cadr b))) bindings) body))))
    (define (gen-lambda params . body) (cons 'lambda (cons params body)))

    ;; (gen-define 'x 1) -> (define x 1); (gen-define '(f a b) body ...) ->
    ;; (define (f a b) body ...) -- `name-or-signature` distinguishes the
    ;; two the same way R7RS's own `define` grammar does (a list vs. a bare
    ;; symbol as the first sub-form).
    (define (gen-define name-or-signature . body) (cons 'define (cons name-or-signature body)))

    ;; ---- control flow ----------------------------------------------------

    (define (gen-if test then . else) (if (null? else) (list 'if test then) (list 'if test then (car else))))
    (define (gen-when test . body) (cons 'when (cons test body)))
    (define (gen-unless test . body) (cons 'unless (cons test body)))

    ;; `clauses` is a list of (test body ...) lists, e.g.
    ;; (list (list test1 body1) (list test2 body2)).
    (define (gen-cond clauses) (cons 'cond clauses))

    ;; `clauses` is a list of ((datum ...) body ...) lists.
    (define (gen-case key-expr clauses) (cons 'case (cons key-expr clauses)))

    (define (gen-and exprs) (cons 'and exprs))
    (define (gen-or exprs) (cons 'or exprs))

    ;; A single expr passes through unwrapped -- generating (begin e) around
    ;; every call site would be needless nesting for the common case of one
    ;; body expression.
    (define (gen-begin exprs)
      (if (and (pair? exprs) (null? (cdr exprs))) (car exprs) (cons 'begin exprs)))

    ;; `bindings` is a list of (var init step) lists (step optional, matching
    ;; R7RS `do`'s own grammar); `test-clause` is (test result ...).
    (define (gen-do bindings test-clause . commands)
      (cons 'do (cons bindings (cons test-clause commands))))

    ;; ---- assignment --------------------------------------------------------

    (define (gen-set! var-expr val-expr) (list 'set! var-expr val-expr))))
