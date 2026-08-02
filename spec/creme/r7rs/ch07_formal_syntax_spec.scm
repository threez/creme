;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/r7rs/ch07_formal_syntax_spec.cr's
;; own cases -- see modules/creme/spec.sld's own header comment for the
;; framework this uses. The original Crystal spec evaluated each case's
;; Scheme source via a fresh sub-interpreter (run(src)/w(src)) since it was
;; testing a Scheme interpreter from OUTSIDE, as Crystal code; here, running
;; directly as Scheme, each case's forms are written and asserted directly
;; via should-equal? instead of comparing write_string'd output against a
;; literal string.
;;
;; The Crystal original also had a `pending` case (never run, just
;; documented) plus an empty §7.2 `describe` -- both carried over below
;; as plain comments rather than `should-*?` assertions or empty
;; `describe` blocks (an empty `(describe ...)` body isn't valid Scheme
;; here the way an empty Crystal `describe do end` is), exactly as the
;; Crystal `pending` never actually asserted anything either.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/r7rs/ch07_formal_syntax_spec.scm
;;   ./bin/creme --self-hosted spec/creme/r7rs/ch07_formal_syntax_spec.scm
;;   ./icecreme/icecreme spec/creme/r7rs/ch07_formal_syntax_spec.scm
;; ===========================================================================

(import (scheme base) (scheme read) (creme spec))

;; PENDING (never asserted in the Crystal original either): the formal
;; <body> grammar (§7.1.1) requires all <definition>s to precede every
;; <expression> within a body -- this implementation allows a definition
;; to follow an expression in a body without error, e.g.
;; (let () (display "x") (define y 1) y) succeeds here instead of being
;; rejected.
;;
;; §7.2's Formal semantics (tail contexts) section has no cases of its
;; own here either, matching the Crystal original: the tail-context
;; positions it enumerates (if/cond/case/and/or/when/unless/let-family/
;; begin/do bodies) are already covered by executable proper-tail-
;; recursion tests derived from this same grammar (ch03_basic_concepts_
;; spec.cr §3.5 in the Crystal suite / its own eventual Scheme port).

(describe "R7RS §7.1 Formal syntax"
  (it "read parses '(+ 2 6)' as data (a 3-element list), distinct from evaluating it as an expression (8)"
    (let ((p (open-input-string "(+ 2 6)")))
      (should-equal? (list (read p) (+ 2 6)) (list '(+ 2 6) 8))))

  ;; Regression test for a genuine bug (not the deliberate non-conformance
  ;; noted above): given that this implementation permits a definition to
  ;; follow an expression in a body, it must still evaluate every
  ;; definition/expression in the body's own source order -- a definition
  ;; appearing after some expression must see that expression's side
  ;; effects, not run before them. The self-hosted compiler used to get
  ;; this wrong (modules/creme/compiler/compiler.sld's own hoist-internal-
  ;; defines): it folded a body's own internal defines into a letrec* by
  ;; bucketing forms into "all defines" (become letrec*'s bindings,
  ;; evaluated before anything else) and "everything else" (become the
  ;; body, run after), silently losing the true interleaved order --
  ;; `found`'s own initializer ran BEFORE `register!`, not after it, even
  ;; though `found`'s own `define` appears textually after `register!` in
  ;; the source. Confirmed this affected icecreme and --self-hosted only (both
  ;; run this same self-hosted compiler); plain native tree-walking
  ;; already evaluated bodies in the correct order. Fixed by keeping
  ;; letrec* only for forward-reference visibility (every defined name
  ;; pre-declared, unassigned) and replacing each definition in place,
  ;; in original order, with an ordinary assignment to its already-
  ;; declared name -- see hoist-internal-defines' own doc comment for
  ;; the full explanation.
  (it "evaluates a body's own definitions and expressions in source order, even interleaved"
    (should-equal?
      (let ()
        (define registry '())
        (define (register! x) (set! registry (cons x registry)))
        (define (f)
          (define worker 42)
          (register! worker)
          (define found registry)
          found)
        (f))
      '(42))))

(spec-summary!)
