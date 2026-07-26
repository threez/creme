;; ===========================================================================
;; A (creme spec)-based port of compiler_spec.cr's `defmacro`-based cases
;; (as opposed to define-syntax/syntax-rules, covered in compiler_spec.scm)
;; -- see modules/creme/spec.sld's own header comment for the framework
;; this uses, and compiler_spec.scm's own header comment for the general
;; approach (should-match-native? compares the self-hosted compiler's
;; output against plain native evaluation of the same source; source is
;; a quoted list of forms here, not a string -- see spec-helper's own
;; header comment on why either works).
;;
;; Also covers fusion suppression after a fusable primitive is redefined
;; (compiler_spec.cr's own "suppresses fusion after a top-level/set!
;; redefinition" cases) -- unrelated to defmacro specifically, but small
;; enough to share this file rather than gain a fourth one of its own.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/compiler_defmacro_spec.scm
;;   ./bin/creme --self-hosted spec/creme/compiler_defmacro_spec.scm
;;   ./cvm/cvm spec/creme/compiler_defmacro_spec.scm
;; ===========================================================================

;; See compiler_spec.scm's own comment on why the full toolchain import
;; list is still needed here even though (creme compiler spec-helper)
;; already imports all of it for itself.
(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(describe "a local defmacro (not define-syntax/syntax-rules) matches native evaluation"
  (it "my-swap! swaps two variables via a synthesized temporary name"
    (should-match-native?
      '((defmacro my-swap! (a b) (list 'let (list (list 'tmp a)) (list 'set! a b) (list 'set! b 'tmp)))
        (define x 1) (define y 2) (my-swap! x y) (list x y))))
  (it "my-list-of ignores its first argument and lists the rest"
    (should-match-native?
      '((defmacro my-list-of (n . items) (cons 'list items))
        (my-list-of 3 1 2 3))))
  (it "my-when expands into an if with a begin body"
    (should-match-native?
      '((defmacro my-when (test . body) (list 'if test (cons 'begin body)))
        (list (my-when (> 2 1) 'yes) (my-when (> 1 2) 'yes))))))

;; NOTE: unlike compiler_spec.cr's own check() (which gives native_eval a
;; BRAND NEW Scheme::Interpreter -- fresh global table -- on every single
;; call), this whole process shares ONE global table between bootstrap-
;; eval and native-eval alike, since load-chunk-bytes always loads into
;; the running interpreter's own global (no isolated-environment option).
;; That's harmless for every other test in this project (redefining a
;; plain name like `f`/`x`/`p` doesn't create cross-call hazards), but
;; these two cases deliberately redefine `+`/`car` THEMSELVES -- fusable
;; primitives other closures capture and later look up dynamically by
;; name. Running the identical redefinition through should-match-native?
;; (bootstrap-eval, then native-eval, against the SAME shared globals)
;; makes the second pass's `(define orig-car car)` capture the FIRST
;; pass's already-wrapped `car`, and that wrapped closure's own body
;; looks up global `orig-car` again at call time -- which by then IS
;; itself, an infinite loop (confirmed empirically: this reproduced a
;; real "recursion depth exceeded" crash before switching to direct
;; assertions below). So these compare bootstrap-eval's result directly
;; against the value native evaluation would give in a FRESH interpreter
;; (verified by hand against compiler_spec.cr's own equivalent cases)
;; instead, and must stay the LAST tests in this file -- both permanently
;; mutate the shared global `+`/`car` for the rest of this process.
(describe "primitive-fusion suppression after redefinition"
  (it "a top-level redefinition of + suppresses fusion for later calls"
    (should-equal?
      (write-to-string
        (bootstrap-eval-forms '((define (my-plus a b) (list 'sum a b)) (define + my-plus) (+ 1 2))))
      "(sum 1 2)"))
  (it "a set!-redefinition of car suppresses fusion for later calls"
    (should-equal?
      (write-to-string
        (bootstrap-eval-forms '((define orig-car car) (set! car (lambda (p) (list 'wrapped (orig-car p)))) (car (cons 1 2)))))
      "(wrapped 1)")))

(spec-summary!)
