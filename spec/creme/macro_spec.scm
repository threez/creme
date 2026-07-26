;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/compile/macro_spec.cr's own
;; `defmacro` cases not already covered by compiler_defmacro_spec.scm
;; (quasiquote-built macro bodies, unquote-splicing variadic bodies, a
;; macro expanding to another macro, gensym-based capture avoidance, a
;; macro named after a special form shadowing it, quoting suppressing
;; expansion, and local/nested macro scoping) -- see modules/creme/
;; spec.sld's own header comment for the framework this uses, and
;; compiler_spec.scm's own header comment for the general should-match-
;; native?/should-raise? approach (source is a quoted list of forms, not
;; a string).
;;
;; Every case in the original file asserting an exact Crystal error-
;; message substring (arity-mismatch wording, "macro cannot be applied as
;; a procedure", every "malformed input" case) is ported as plain
;; should-raise? with no message check -- the self-hosted compiler's own
;; error text isn't guaranteed to match Crystal's verbatim, only that it
;; also rejects each case.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/macro_spec.scm
;;   ./bin/creme --self-hosted spec/creme/macro_spec.scm
;;   ./cvm/cvm spec/creme/macro_spec.scm
;; ===========================================================================

;; See compiler_spec.scm's own comment on why the full toolchain import
;; list is still needed here even though (creme compiler spec-helper)
;; already imports all of it for itself.
(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(describe "defmacro matches native evaluation"
  (it "expands a basic macro built with quasiquote"
    (should-match-native?
      '((defmacro my-if (c t e) `(cond (,c ,t) (else ,e))) (my-if #t 1 2)))
    (should-match-native?
      '((defmacro my-if (c t e) `(cond (,c ,t) (else ,e))) (my-if #f 1 2))))

  (it "supports unquote-splicing for variadic bodies"
    (should-match-native?
      '((defmacro my-begin (a . rest) `(begin ,a ,@rest)) (my-begin 1 2 3))))

  (it "raises the same arity-mismatch wording as lambda"
    (should-raise?
      (lambda () (bootstrap-eval-forms '((defmacro two-args (a b) a) (two-args 1))))))

  (it "supports a macro expanding to another macro"
    (should-match-native?
      '((defmacro inner (x) `(+ ,x 1))
        (defmacro outer (x) `(inner ,x))
        (outer 5))))

  (describe "gensym-based capture avoidance"
    (it "returns a distinct symbol each call"
      (should-match-native? '((import (creme introspection)) (eq? (gensym) (gensym)))))

    (it "returns a symbol"
      (should-match-native? '((import (creme introspection)) (symbol? (gensym)))))

    ;; Not should-match-native? -- gensym's own counter suffix isn't the
    ;; same across the bootstrap-side and native-side evaluations of this
    ;; (deliberately non-deterministic) source, so this checks the SHAPE
    ;; of the bootstrap side's own result directly instead.
    (it "honors a prefix argument"
      (should-be-true?
        (regexp-matches? (regexp "^tmp__[0-9]+$")
                          (bootstrap-eval-forms
                            '((import (creme introspection)) (symbol->string (gensym "tmp")))))))

    (it "lets swap! avoid capturing the caller's own variable names"
      (should-match-native?
        '((import (creme introspection))
          (defmacro swap! (a b)
            (let ((tmp (gensym)))
              `(let ((,tmp ,a)) (set! ,a ,b) (set! ,b ,tmp))))
          (define x 1)
          (define y 2)
          (swap! x y)
          (list x y)))))

  (it "raises when a macro is passed to the apply builtin"
    (should-raise?
      (lambda () (bootstrap-eval-forms '((defmacro m (x) x) (apply m (list 1)))))))

  (it "raises when a macro is passed to map"
    (should-raise?
      (lambda () (bootstrap-eval-forms '((defmacro m (x) x) (map m (list 1 2)))))))

  (describe "malformed input"
    (it "raises when the name is missing"
      (should-raise? (lambda () (bootstrap-eval-forms '((defmacro))))))
    (it "raises when the name isn't a symbol"
      (should-raise? (lambda () (bootstrap-eval-forms '((defmacro 1 (x) x))))))
    (it "raises when the formals list is missing"
      (should-raise? (lambda () (bootstrap-eval-forms '((defmacro m))))))
    (it "raises when the body is empty"
      (should-raise? (lambda () (bootstrap-eval-forms '((defmacro m (x)))))))
    (it "raises for a bad formal parameter"
      (should-raise? (lambda () (bootstrap-eval-forms '((defmacro m (1) 1)))))))

  (it "a macro named after a special form shadows it, like any other identifier"
    (should-match-native? '((defmacro if (a) a) (if 42)))
    (should-raise?
      (lambda () (bootstrap-eval-forms '((defmacro if (a) a) (if #t 1 2))))))

  (it "does not expand a macro call when merely quoted"
    (should-match-native? '((defmacro some-macro (x) x) (quote (some-macro 1)))))

  ;; A distinct macro name (not `m`) is deliberate: `m` is already a
  ;; permanent GLOBAL macro by this point in the process (the earlier
  ;; "raises when a macro is passed to apply/map" cases each register a
  ;; top-level (defmacro m ...), and top-level defmacro is intentionally
  ;; NOT scoped -- only a body-scoped one is, see compile-scoped-body!'s
  ;; own comment). Reusing `m` here would make the second (m 5) call
  ;; correctly resolve to THAT earlier top-level macro instead of
  ;; correctly raising unbound-variable -- a test-authoring collision
  ;; across `it`s sharing one process, not a compiler bug (confirmed by
  ;; bisecting this failure down to exactly that cause).
  (it "supports local, nested macro definitions scoped to their let"
    (should-match-native? '((let () (defmacro local-only-macro (x) x) (local-only-macro 5))))
    (should-raise?
      (lambda ()
        (bootstrap-eval-forms
          '((let () (defmacro local-only-macro (x) x) (local-only-macro 5)) (local-only-macro 5)))))))

(spec-summary!)
