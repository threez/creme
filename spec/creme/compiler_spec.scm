;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/modules/creme/compiler/
;; compiler_spec.cr's own "compiles and runs programs matching native
;; evaluation" cases -- see modules/creme/spec.sld's own header comment for
;; the framework this uses. Each case compiles a snippet with the SELF-
;; HOSTED compiler and checks it against plain native evaluation of the
;; same snippet, exactly like compiler_spec.cr's own check() helper, but
;; entirely as a running Scheme program with no Crystal spec process
;; involved.
;;
;; Sibling files port the rest of compiler_spec.cr's cases:
;;   compiler_defmacro_spec.scm  -- defmacro-based macros, fusion-
;;                                  suppression-after-redefinition
;;   compiler_libraries_spec.scm -- pure-Scheme file-based libraries
;;                                  (dao/sxql/import filters/generated
;;                                  library/rejecting a non-top-level
;;                                  import)
;;   compiler_self_host_spec.scm -- the compiler compiling ITSELF, and the
;;                                  one case that intentionally does NOT
;;                                  match native evaluation
;;
;; Run with:
;;   ./bin/creme spec/creme/compiler_spec.scm            (native Crystal VM)
;;   ./bin/creme --self-hosted spec/creme/compiler_spec.scm
;; (not yet `--cvm` -- see (creme spec)'s own header comment on why.)
;; ===========================================================================

;; The full toolchain import list below is still needed here even though
;; (creme compiler spec-helper) already imports all of it FOR ITSELF:
;; native-eval's `(eval form)` call always runs `form` against THIS
;; SCRIPT's own shared global table (Crystal's `eval` builtin ignores its
;; caller's own lexical env for the 1-arg case -- see src/scheme/modules/
;; scheme/eval.cr), which is populated only by imports THIS FILE makes
;; directly, not by a library it imports importing them for its own
;; private use. Every should-match-native? test source below that uses
;; e.g. `write`, `force`, `eval`, or a (creme regex) call needs that name
;; already bound here for exactly that reason.
(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(describe "self-hosted compiler matches native evaluation"

  (describe "arithmetic, conditionals, let, and/or, recursion"
    (it "adds numbers" (should-match-native? "(+ 1 2 3)"))
    (it "if with a true test" (should-match-native? "(if (> 3 2) 'yes 'no)"))
    (it "if with a false test and no else" (should-match-native? "(if (> 2 3) 'yes)"))
    (it "let with two bindings" (should-match-native? "(let ((x 1) (y 2)) (+ x y))"))
    (it "and/or short-circuiting" (should-match-native? "(list (and 1 2 3) (and 1 #f 3) (and) (or #f #f 5) (or #f #f #f) (or))"))
    (it "defines and calls a recursive function" (should-match-native? "(define (fact n) (if (= n 0) 1 (* n (fact (- n 1))))) (fact 10)"))
    (it "a variadic rest-arg function" (should-match-native? "(define (f a . rest) (cons a rest)) (f 1 2 3 4)"))
    (it "closes over an outer variable" (should-match-native? "(define (make-adder n) (lambda (x) (+ x n))) ((make-adder 5) 10)"))
    (it "cond with an => clause" (should-match-native? "(define (classify x) (cond ((assv x (list (cons 1 'one) (cons 2 'two))) => cdr) ((< x 0) 'negative) (else 'other))) (list (classify 1) (classify 2) (classify -5) (classify 42))"))
    (it "a named-let loop summing a vector" (should-match-native? "(define (sum-vec v) (let loop ((i 0) (acc 0)) (if (= i (vector-length v)) acc (loop (+ i 1) (+ acc (vector-ref v i)))))) (sum-vec (vector 1 2 3 4 5))")))

  (describe "define semantics"
    (it "begin sequences multiple top-level defines" (should-match-native? "(begin (define x 1) (define y 2) (+ x y))"))
    ;; A bare (define ...) as a program's own LAST top-level form must
    ;; evaluate to the defined NAME (a symbol), not the value it was
    ;; defined to -- found by comparing disassembled bytecode against
    ;; native for the same source: this compiler previously loaded the
    ;; VALUE register into dest here instead, diverging only in this
    ;; specific (last-form-is-a-bare-define) position.
    (it "a bare top-level (define ...) evaluates to the defined name (function)" (should-match-native? "(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))"))
    (it "a bare top-level (define ...) evaluates to the defined name (value)" (should-match-native? "(define x 42)"))
    (it "an internal define inside begin is visible after the begin" (should-match-native? "(list (begin (define z 1)) z)")))

  (describe "records"
    (it "define-record-type supports mutation and multiple fields" (should-match-native? "(define-record-type <point> (make-point x y) point? (x point-x set-point-x!) (y point-y)) (define p (make-point 3 4)) (set-point-x! p 10) (list (point? p) (point? 5) (point-x p) (point-y p))"))
    ;; A top-level record is a genuine SchemeRecord now, not a tagged
    ;; vector -- vector?/write on it must match native evaluation exactly
    ;; (previously bootstrap wrongly answered vector? #t and printed a
    ;; #(...) vector literal instead of a #<point ...> record).
    (it "a record is not a vector" (should-match-native? "(define-record-type <pt2> (make-pt2 x y) pt2? (x pt2-x) (y pt2-y)) (define q (make-pt2 1 2)) (list (vector? q) (pt2? q) q)")))

  (describe "closures and mutation"
    (it "a counter closure captures and mutates its own state" (should-match-native? "(define (counter) (let ((n 0)) (lambda () (set! n (+ n 1)) n))) (define c (counter)) (list (c) (c) (c))"))
    (it "set! on a top-level variable" (should-match-native? "(define x 1) (set! x (+ x 41)) x")))

  (describe "case"
    (it "dispatches on a hashable datum" (should-match-native? "(define (classify n) (case n ((1 2 3) 'small) ((4 5 6) 'medium) (else 'large))) (list (classify 2) (classify 5) (classify 99))"))
    ;; case with a => clause (calls the proc on the KEY's own value, not
    ;; a boolean), and case keyed on symbols/chars (eqv?, not eq?/=)
    ;; rather than just integers, exercising Op::CaseMatch's own eqv?
    ;; comparison across value types.
    (it "a => clause receives the matched key" (should-match-native? "(define (f n) (case n ((1 2 3) => (lambda (x) (* x 10))) (else 'other))) (list (f 2) (f 99))"))
    (it "dispatches on symbols" (should-match-native? "(define (f s) (case s ((a b) 'ab) ((c) 'c) (else 'other))) (list (f 'a) (f 'b) (f 'c) (f 'z))"))
    (it "dispatches on chars" (should-match-native? "(define (f c) (case c ((#\\a #\\b) 'ab) (else 'other))) (list (f #\\a) (f #\\z))")))

  (describe "do loop"
    (it "a do loop accumulating a sum" (should-match-native? "(do ((i 0 (+ i 1)) (acc 0 (+ acc i))) ((= i 5) acc))")))

  (describe "letrec / letrec*"
    (it "mutually recursive even?/odd? via letrec" (should-match-native? "(letrec ((even? (lambda (n) (if (= n 0) #t (odd? (- n 1))))) (odd? (lambda (n) (if (= n 0) #f (even? (- n 1)))))) (list (even? 10) (odd? 10)))"))
    (it "letrec* sees an earlier binding from a later one" (should-match-native? "(letrec* ((x 1) (y (+ x 1))) (+ x y))")))

  (describe "quasiquote"
    (it "unquote and unquote-splicing in a list template" (should-match-native? "(let ((a 1) (b 2) (c 3)) `(x ,a ,@(list b c) y))"))
    (it "unquote in a vector template" (should-match-native? "`#(1 ,(+ 1 1) 3)"))
    (it "nested quasiquote (inner unquote stays quoted)" (should-match-native? "(let ((x 1)) `(a `(b ,(+ 1 2) ,,x)))"))
    (it "unquote in operator position builds a define form" (should-match-native? "(let ((name 'foo) (val 42)) `(define ,name ,val))")))

  (describe "call/cc, dynamic-wind, case-lambda"
    (it "call/cc returning normally and via an escape" (should-match-native? "(+ (call/cc (lambda (k) 1)) (call/cc (lambda (k) (k 10) 999)))"))
    (it "dynamic-wind runs before/during/after" (should-match-native? "(dynamic-wind (lambda () 'before) (lambda () 'during) (lambda () 'after))"))
    (it "case-lambda dispatches on argument count" (should-match-native? "(define f (case-lambda ((a) (list 'one a)) ((a b) (list 'two a b)) ((a b . rest) (list 'many a b rest)))) (list (f 1) (f 1 2) (f 1 2 3 4))")))

  (describe "numeric and bytevector literals"
    (it "rationals, negative rationals, a complex, and a bytevector literal" (should-match-native? "'(1/2 -3/4 1+2i #u8(1 2 3))"))
    (it "flonums and division" (should-match-native? "(list 3.14 -2.5 1e10 (/ 1.0 3))")))

  (describe "multiple values"
    (it "let-values destructures two values() calls" (should-match-native? "(let-values (((a b) (values 1 2)) ((c) (values 3))) (list a b c))"))
    (it "let*-values sees an earlier binding from a later one" (should-match-native? "(let*-values (((a b) (values 1 2)) ((c) (values (+ a b)))) (list a b c))"))
    (it "top-level define-values" (should-match-native? "(define-values (a b) (values 10 20)) (+ a b)"))
    (it "call-with-values" (should-match-native? "(call-with-values (lambda () (values 1 2 3)) list)")))

  (describe "guard / error handling"
    (it "guard catches a raised error and reads its message" (should-match-native? "(guard (e (#t (list 'caught (error-object-message e)))) (error \"boom\"))"))
    (it "guard's clauses dispatch on the raised value" (should-match-native? "(guard (e ((symbol? e) (list 'sym e)) (else (list 'other e))) (raise 'oops))"))
    (it "guard used as an ordinary sub-expression" (should-match-native? "(+ 1 (guard (e (#t 100)) (car '())))"))
    (it "guard around a division by zero" (should-match-native? "(define (safe-div a b) (guard (e (#t 'error)) (/ a b))) (list (safe-div 10 2) (safe-div 10 0))")))

  (describe "define-syntax / syntax-rules macros"
    (it "a variadic list-building macro" (should-match-native? "(define-syntax my-list (syntax-rules () ((_ e ...) (list e ...)))) (my-list 1 2 3 4)"))
    (it "swap! mutates both bindings via a temporary" (should-match-native? "(define-syntax swap! (syntax-rules () ((_ a b) (let ((tmp a)) (set! a b) (set! b tmp))))) (define x 1) (define y 2) (swap! x y) (list x y)"))
    (it "a recursive variadic or-like macro" (should-match-native? "(define-syntax my-or2 (syntax-rules () ((_ ) #f) ((_ e) e) ((_ e1 e2 ...) (let ((mor-t e1)) (if mor-t mor-t (my-or2 e2 ...)))))) (list (my-or2) (my-or2 5) (my-or2 #f #f 7) (my-or2 #f #f #f))"))
    (it "a recursive let*-like macro" (should-match-native? "(define-syntax my-let-star (syntax-rules () ((_ () body ...) (let () body ...)) ((_ ((n v) rest ...) body ...) (let ((n v)) (my-let-star (rest ...) body ...))))) (my-let-star ((a 1) (b (+ a 1)) (c (+ b 1))) (list a b c))"))
    (it "a cond-like macro with a literal else keyword" (should-match-native? "(define-syntax my-cond (syntax-rules (else) ((_ (else e ...)) (begin e ...)) ((_ (test e ...) clause ...) (if test (begin e ...) (my-cond clause ...))))) (my-cond ((= 1 2) 'a) ((= 1 1) 'b) (else 'c))"))
    (it "a macro expanding to a fusable primitive call still fuses" (should-match-native? "(define-syntax my-add (syntax-rules () ((_ a b) (+ a b)))) (my-add 3 4)"))

    (describe "let-syntax / letrec-syntax scoping"
      (it "let-syntax's macro is local to its own body" (should-match-native? "(let-syntax ((double (syntax-rules () ((_ x) (* 2 x))))) (list (double 5) (double 10)))"))
      (it "letrec-syntax's own body can see an outer macro" (should-match-native? "(define-syntax outer-macro (syntax-rules () ((_ x) (+ x 1)))) (letrec-syntax ((double (syntax-rules () ((_ x) (* 2 (outer-macro x)))))) (double 5))"))
      ;; let-syntax/letrec-syntax scoping edge cases -- the Creme compiler
      ;; uses a whole-macro-table snapshot/restore (compile-let-syntax!)
      ;; instead of Crystal's own parent-chained MacroEnv (analyze_let_
      ;; syntax); these check that's behaviorally equivalent for shadowing
      ;; an outer macro of the same name (and correctly un-shadowing it
      ;; afterward), sibling let-syntax forms not leaking into each other,
      ;; and nested let-syntax shadowing an enclosing let-syntax's own
      ;; same-named macro.
      (it "an inner let-syntax shadows, then un-shadows, an outer same-named macro" (should-match-native? "(define-syntax id (syntax-rules () ((_ x) (list 'outer x)))) (list (id 1) (let-syntax ((id (syntax-rules () ((_ x) (list 'inner x))))) (id 2)) (id 3))"))
      (it "sibling let-syntax forms don't leak into each other" (should-match-native? "(list (let-syntax ((tag (syntax-rules () ((_ x) (list 'a x))))) (tag 1)) (let-syntax ((tag (syntax-rules () ((_ x) (list 'b x))))) (tag 2)))"))
      (it "nested let-syntax shadows an enclosing let-syntax's own macro" (should-match-native? "(let-syntax ((tag (syntax-rules () ((_ x) (list 'outer x))))) (list (tag 1) (let-syntax ((tag (syntax-rules () ((_ x) (list 'inner x))))) (tag 2)) (tag 3)))"))))

  (describe "parameterize"
    (it "parameterize temporarily rebinds a parameter" (should-match-native? "(define p (make-parameter 10)) (list (p) (parameterize ((p 20)) (p)) (p))"))
    (it "parameterize rebinds two parameters at once" (should-match-native? "(define p1 (make-parameter 1)) (define p2 (make-parameter 2)) (parameterize ((p1 100) (p2 200)) (+ (p1) (p2)))")))

  (describe "delay / force"
    (it "force memoizes a delayed computation" (should-match-native? "(define pr (delay (begin (+ 1 2)))) (list (force pr) (force pr))")))

  (describe "eval"
    (it "eval on a quoted form" (should-match-native? "(eval '(+ 1 2 3))")))

  (describe "internal define inside a non-scope-introducing begin"
    (it "an internal define inside a begin, used after the begin" (should-match-native? "(define (f) (display \"a\") (begin (define y 10)) (+ y 1)) (f)")))

  (describe "cond-expand"
    (it "an else-only clause" (should-match-native? "(cond-expand (else 'ok))"))
    (it "falls through a missing library to the next clause" (should-match-native? "(cond-expand ((library (does not exist)) 'no) (r7rs 'yes) (else 'fallback))"))
    (it "the creme feature identifier" (should-match-native? "(cond-expand (creme 'yes) (else 'no))"))
    (it "an (and ...) of two feature identifiers" (should-match-native? "(cond-expand ((and creme creme.cr) 'yes) (else 'no))"))
    (it "an (or ...) mixing a library clause and a feature identifier" (should-match-native? "(cond-expand ((or (library (does not exist)) creme) 'yes) (else 'no))")))

  (describe "imports"
    (it "a plain import of a native library" (should-match-native? "(import (creme regex)) (regexp-matches? (regexp \"a+\") \"aaa\")"))
    (it "an only-filtered import" (should-match-native? "(import (only (creme regex) regexp regexp-matches?)) (regexp-matches? (regexp \"[0-9]+\") \"42\")")))

  (describe "when / unless"
    (it "when runs its body only on a true test" (should-match-native? "(define (f x) (when (> x 0) (display \"pos \") x)) (list (f 5) (f -5))"))
    (it "unless runs its body only on a false test" (should-match-native? "(define (f x) (unless (> x 0) (display \"nonpos \") x)) (list (f 5) (f -5))")))

  (describe "vectors and bytevectors"
    (it "vector-ref on a literal vector" (should-match-native? "(define v #(1 2 3)) (vector-ref v 1)"))
    (it "bytevector-u8-ref on a literal bytevector" (should-match-native? "(define bv #u8(1 2 3)) (bytevector-u8-ref bv 2)")))

  (describe "primitive-call fusion"
    ;; Exact arity required (a 3-arg + must NOT fuse, still correct via
    ;; the variadic builtin).
    (it "a 3-arg + does not fuse but is still correct" (should-match-native? "(+ 1 2 3)"))
    ;; Locally shadowed name must NOT fuse (ordinary Call to the shadow).
    (it "a locally shadowed + is not fused" (should-match-native? "(let ((+ -)) (+ 5 2))"))
    ;; Nested-argument fusable calls -- arguments are themselves calls,
    ;; not bare variables/literals.
    (it "fusable calls nested as each other's arguments" (should-match-native? "(define (foo x) (* x 2)) (define (bar y) (+ y 3)) (+ (foo 4) (bar 5))"))
    ;; Tail-position fusion: arithmetic/comparison (has a *Return variant)
    ;; and an accessor (doesn't -- base op + explicit Return).
    (it "a fused arithmetic op in tail position" (should-match-native? "(define (f x) (+ x 1)) (f 41)"))
    (it "a fused comparison in tail position" (should-match-native? "(define (g x) (< x 10)) (list (g 5) (g 50))"))
    (it "a fused accessor in tail position" (should-match-native? "(define (h v) (vector-ref v 0)) (h #(9 8 7))"))
    (it "car fused in tail position" (should-match-native? "(define (k p) (car p)) (k (cons 1 2))"))
    ;; Mutator fusion (vector-set!/string-set!), including the
    ;; dest == object-register case (the call's own dest register is
    ;; never read, matching typical (begin (vector-set! ...) ) usage).
    (it "vector-set! fusion, result is the mutated vector" (should-match-native? "(define v (vector 1 2 3)) (vector-set! v 1 99) v"))
    (it "string-set! fusion, result is the mutated string" (should-match-native? "(define s (make-string 3 #\\a)) (string-set! s 1 #\\z) s"))
    (it "two sequential vector-set! calls on the same vector" (should-match-native? "(let ((v (vector 0 0))) (vector-set! v 0 1) (vector-set! v 1 2) v)"))

    (describe "direct call fusion (CallGlobal/CallLocal/CallUpval, TailCall*)"
      (it "a self-recursive tail call" (should-match-native? "(define (count-down n) (if (= n 0) 'done (count-down (- n 1)))) (count-down 100000)"))
      (it "a non-tail call to another top-level global" (should-match-native? "(define (helper x) (* x x)) (define (caller y) (+ (helper y) 1)) (caller 5)"))
      (it "a call to a let-bound local callable" (should-match-native? "(let ((f (lambda (x) (* x 2)))) (f 21))"))
      (it "a call to an upvalue-captured callable" (should-match-native? "(define (make-caller g) (lambda (x) (g x))) ((make-caller (lambda (x) (+ x 1))) 9)")))

    (describe "*Imm operand specialization (literal 2nd operand)"
      (it "subtraction with a literal operand" (should-match-native? "(- 10 1)"))
      (it "comparison at the Int32 boundary" (should-match-native? "(< 5 2147483647)"))
      (it "eq? with a literal symbol operand" (should-match-native? "(eq? 'x 'y)"))
      (it "vector-set! with a literal index" (should-match-native? "(vector-set! (vector 1 2 3) 1 99)"))
      (it "addition just past the Int32 boundary falls back correctly" (should-match-native? "(+ 1 3000000000)"))
      (it "subtraction just past the Int32 boundary falls back correctly" (should-match-native? "(- 1 3000000000)")))

    (describe "*Up operand specialization (an upvalue-captured invariant operand)"
      (it "a named-let loop comparing against a closed-over bound" (should-match-native? "(define (sum-to n) (let loop ((i 0) (acc 0)) (if (< i n) (loop (+ i 1) (+ acc i)) acc))) (sum-to 1000)"))
      (it "a named-let loop indexing a closed-over vector" (should-match-native? "(define (vsum v) (let ((len (vector-length v))) (let loop ((i 0) (acc 0)) (if (= i len) acc (loop (+ i 1) (+ acc (vector-ref v i))))))) (vsum (vector 1 2 3 4 5))"))
      (it "a named-let loop mutating a closed-over vector" (should-match-native? "(define (fill-with! v x) (let loop ((i 0)) (if (< i (vector-length v)) (begin (vector-set! v i x) (loop (+ i 1))) v))) (fill-with! (vector 0 0 0) 7)")))

    (describe "fused compare-and-branch"
      (it "a fused comparison used directly as an if-test, both branches" (should-match-native? "(list (if (< 1 2) 'yes 'no) (if (< 2 1) 'yes 'no))"))
      (it "a fused comparison in an if with no else clause" (should-match-native? "(if (< 10 5) 'unreachable)"))
      (it "unless with a fused comparison condition" (should-match-native? "(define (f x) (unless (< x 0) 'nonneg)) (list (f 5) (f -5))"))
      (it "when with a fused comparison condition" (should-match-native? "(define (f x) (when (< x 0) 'neg)) (list (f 5) (f -5))"))
      (it "a fused comparison as a named-let loop's own test" (should-match-native? "(define (f n) (let loop ((i 0)) (if (< i n) (loop (+ i 1)) i))) (f 50)"))
      (it "a fused comparison against a closed-over bound as a loop test" (should-match-native? "(define (g v) (let ((n (vector-length v))) (let loop ((i 0)) (if (= i n) 'done (loop (+ i 1)))))) (g (vector 1 2 3))"))
      (it "a shadowed comparison operator in test position is not fused" (should-match-native? "(let ((< >)) (list (if (< 1 2) 'yes 'no) (if (< 2 1) 'yes 'no)))"))
      (it "eq? on two identical quoted symbols" (should-match-native? "(eq? 'a 'a)"))))

  (describe "fast in-place tail-call argument compilation"
    (it "a genuinely unchanged pass-through argument" (should-match-native? "(define (count-with-limit i limit) (if (= i limit) 'done (count-with-limit (+ i 1) limit))) (count-with-limit 0 1000)"))
    ;; Exercises the scratch/deferred-Move hazard path: a tail call whose
    ;; arguments swap two registers -- an even number of swaps must return
    ;; to the original values.
    (it "a tail call that swaps two bare-variable arguments" (should-match-native? "(define (swap-loop n a b) (if (= n 0) (list a b) (swap-loop (- n 1) b a))) (swap-loop 4 1 2)"))
    ;; leaf-expr? recognizes a fusable-primitive call (whose own arguments
    ;; are all leaves too) as a leaf, mirroring bytecode_compiler.cr's own
    ;; recursive leaf_node? -- but that also widens which tail calls take
    ;; the fast in-place-argument path (every-leaf?), which depends on
    ;; arg-reads-register? correctly detecting a register read INSIDE a
    ;; compound leaf argument, not just a bare symbol. This case swaps two
    ;; parameters via compound (fusable-call) expressions rather than bare
    ;; variables, which must still take the deferred-scratch-register
    ;; path -- silently reading the WRONG (already-overwritten) value if
    ;; arg-reads-register? didn't recurse into it.
    (it "a tail call that swaps two arguments via compound leaf expressions" (should-match-native? "(define (swap-loop-compound n a b) (if (= n 0) (list a b) (swap-loop-compound (- n 1) (+ b 0) (+ a 0)))) (swap-loop-compound 4 1 2)"))
    (it "a closure created in a loop body captures that iteration's value" (should-match-native? "(define (loop-with-closure n) (let loop ((i 0) (snapshots '())) (if (= i n) (map (lambda (f) (f)) (reverse snapshots)) (let ((snap (lambda () i))) (loop (+ i 1) (cons snap snapshots)))))) (loop-with-closure 5)")))

  (describe "scope-based register reclaim"
    (it "several sequential sibling let scopes don't grow the register count unboundedly" (should-match-native? "(define (f) (let ((a 1)) a) (let ((b 2)) b) (let ((c 3)) c) (let ((d 4)) d) 'done) (f)"))
    (it "a deeply nested arithmetic expression inside a loop" (should-match-native? "(define (deep n) (let loop ((i 0) (acc 0)) (if (= i n) acc (loop (+ i 1) (+ acc (* (+ i 1) (- i 1) (+ i i))))))) (deep 200)"))
    (it "case-lambda reclaim points" (should-match-native? "(define f (case-lambda ((a) (list 'one a)) ((a b) (+ a b)) ((a b . rest) (list a b rest)))) (list (f 1) (f 1 2) (f 1 2 3 4))"))
    (it "parameterize reclaim points" (should-match-native? "(define p (make-parameter 1)) (define (g) (parameterize ((p 10)) (+ (p) (p)))) (list (g) (g) (p))")))

  (describe "internal define/define-values/define-record-type hoisting in every body position"
    (it "an internal define in a cond else clause" (should-match-native? "(define (f x) (cond (else (define y (* x 2)) (+ y 1)))) (f 5)"))
    (it "an internal define in a plain cond clause" (should-match-native? "(define (f x) (cond ((> x 0) (define y (* x 2)) (+ y 1)) (else 'neg))) (list (f 5) (f -5))"))
    (it "an internal define in a case clause" (should-match-native? "(define (f n) (case n ((1 2 3) (define y 'small) y) (else (define y 'large) y))) (list (f 2) (f 99))"))
    (it "an internal define in a when body" (should-match-native? "(define (f x) (when (> x 0) (define y (* x 10)) y)) (list (f 5) (f -5))"))
    (it "an internal define in an unless body" (should-match-native? "(define (f x) (unless (> x 0) (define y (* x 10)) y)) (list (f 5) (f -5))"))
    (it "an internal define-values with fixed arity" (should-match-native? "(define (f) (define-values (a b) (values 1 2)) (+ a b)) (f)"))
    (it "an internal define-values with a rest arg" (should-match-native? "(define (f) (define-values (a . rest) (values 1 2 3)) (list a rest)) (f)"))
    (it "an internal define-values inside a let body" (should-match-native? "(let () (define-values (a b c) (values 1 2 3)) (* a b c))"))
    (it "an internal define-record-type inside a lambda body" (should-match-native? "(define (f) (define-record-type <pt> (make-pt x y) pt? (x pt-x set-pt-x!) (y pt-y)) (define p (make-pt 3 4)) (set-pt-x! p 9) (list (pt? p) (pt-x p) (pt-y p))) (f)"))
    (it "an internal define-record-type inside a cond clause" (should-match-native? "(define (f flag) (cond (flag (define-record-type <box> (make-box v) box? (v box-v)) (box-v (make-box 42))) (else 'no))) (list (f #t) (f #f))"))))

(spec-summary!)
