require "../../../../spec_helper"

private def load_toolchain(interp : Creme::Interpreter) : Nil
  Creme.run_source(interp, %((import (scheme lazy) (scheme eval) (scheme cxr) (creme peg) (creme regex) (creme bytecode) (creme bootstrap) (creme compiler reader) (creme compiler compiler))))
  # Pre-seeds ensure-library-loaded!'s own tracking for every file-based
  # library just loaded NATIVELY above -- see src/main.cr's
  # SELF_HOSTED_TOOLCHAIN_MARK_LOADED's own doc comment for why this is
  # needed now that compiler.sld's own file-reading (file-read) genuinely
  # works reentrant here too: without it, a script that ALSO imports one
  # of these same libraries has its source re-read and re-run a SECOND
  # time, corrupting an in-progress record type (e.g. (creme bytecode)'s
  # own <chunk>).
  Creme.run_source(interp, %(
    (mark-self-hosted-library-loaded! '(creme peg))
    (mark-self-hosted-library-loaded! '(creme bytecode))
    (mark-self-hosted-library-loaded! '(creme compiler reader))
    (mark-self-hosted-library-loaded! '(creme compiler compiler))))
end

private def native_eval(source : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme lazy) (scheme eval)) #{source}").write_string
end

private def bootstrap_eval(interp : Creme::Interpreter, source : String) : String
  interp.global.define("compiler-test-source", Creme::SchemeStr.new(source))
  Creme.run_source(interp, "(load-chunk-bytes (compile-source-to-bytes compiler-test-source))").write_string
end

private def check(interp : Creme::Interpreter, source : String) : Nil
  bootstrap_eval(interp, source).should eq(native_eval(source))
end

private def cons_to_array(v : Creme::SchemeValue) : Array(Creme::SchemeValue)
  arr = [] of Creme::SchemeValue
  cur = v
  while cur.is_a?(Creme::Cons)
    arr << cur.car
    cur = cur.cdr
  end
  arr
end

# Extracts the (begin form1 form2 ...) clause's own forms out of a
# (define-library (creme name) (export ...) (import ...) (begin ...))
# file -- the self-compile tests need these AS SOURCE TEXT (joined back
# via write_string, then re-read by the bootstrap reader itself), since
# compile-source-to-bytes compiles a flat sequence of top-level forms,
# not a define-library wrapper.
private def library_body_source(path : String) : String
  top = Creme::Reader.read_all(File.read(path)).first.as(Creme::Cons)
  clauses = cons_to_array(top.cdr)[1..] # drop the (creme name) library-name clause
  begin_clause = clauses.find { |clause| clause.is_a?(Creme::Cons) && clause.car.is_a?(Creme::SchemeSym) && clause.car.as(Creme::SchemeSym).name == "begin" }.as(Creme::Cons)
  cons_to_array(begin_clause.cdr).map(&.write_string).join("\n")
end

describe "bootstrap-compiler module" do
  it "compiles and runs programs matching native evaluation" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    load_toolchain(interp)
    [
      "(+ 1 2 3)",
      "(if (> 3 2) 'yes 'no)",
      "(if (> 2 3) 'yes)",
      "(let ((x 1) (y 2)) (+ x y))",
      "(list (and 1 2 3) (and 1 #f 3) (and) (or #f #f 5) (or #f #f #f) (or))",
      "(define (fact n) (if (= n 0) 1 (* n (fact (- n 1))))) (fact 10)",
      "(define (f a . rest) (cons a rest)) (f 1 2 3 4)",
      "(define (make-adder n) (lambda (x) (+ x n))) ((make-adder 5) 10)",
      "(define (classify x) (cond ((assv x (list (cons 1 'one) (cons 2 'two))) => cdr) ((< x 0) 'negative) (else 'other))) (list (classify 1) (classify 2) (classify -5) (classify 42))",
      "(define (sum-vec v) (let loop ((i 0) (acc 0)) (if (= i (vector-length v)) acc (loop (+ i 1) (+ acc (vector-ref v i)))))) (sum-vec (vector 1 2 3 4 5))",
      "(begin (define x 1) (define y 2) (+ x y))",
      # A bare (define ...) as a program's own LAST top-level form must
      # evaluate to the defined NAME (a symbol), not the value it was
      # defined to -- found by comparing disassembled bytecode against
      # native for the same source: this compiler previously loaded the
      # VALUE register into dest here instead, diverging only in this
      # specific (last-form-is-a-bare-define) position.
      "(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))",
      "(define x 42)",
      "(list (begin (define z 1)) z)",
      %((define-record-type <point> (make-point x y) point? (x point-x set-point-x!) (y point-y)) (define p (make-point 3 4)) (set-point-x! p 10) (list (point? p) (point? 5) (point-x p) (point-y p))),
      # A top-level record is a genuine SchemeRecord now, not a tagged
      # vector -- vector?/write on it must match native evaluation exactly
      # (previously bootstrap wrongly answered vector? #t and printed a
      # #(...) vector literal instead of a #<point ...> record).
      %((define-record-type <pt2> (make-pt2 x y) pt2? (x pt2-x) (y pt2-y)) (define q (make-pt2 1 2)) (list (vector? q) (pt2? q) q)),
      "(define (counter) (let ((n 0)) (lambda () (set! n (+ n 1)) n))) (define c (counter)) (list (c) (c) (c))",
      "(define x 1) (set! x (+ x 41)) x",
      "(define (classify n) (case n ((1 2 3) 'small) ((4 5 6) 'medium) (else 'large))) (list (classify 2) (classify 5) (classify 99))",
      # case with a => clause (calls the proc on the KEY's own value, not
      # a boolean), and case keyed on symbols/chars (eqv?, not eq?/=)
      # rather than just integers, exercising Op::CaseMatch's own eqv?
      # comparison across value types.
      "(define (f n) (case n ((1 2 3) => (lambda (x) (* x 10))) (else 'other))) (list (f 2) (f 99))",
      "(define (f s) (case s ((a b) 'ab) ((c) 'c) (else 'other))) (list (f 'a) (f 'b) (f 'c) (f 'z))",
      "(define (f c) (case c ((#\\a #\\b) 'ab) (else 'other))) (list (f #\\a) (f #\\z))",
      "(do ((i 0 (+ i 1)) (acc 0 (+ acc i))) ((= i 5) acc))",
      "(letrec ((even? (lambda (n) (if (= n 0) #t (odd? (- n 1))))) (odd? (lambda (n) (if (= n 0) #f (even? (- n 1)))))) (list (even? 10) (odd? 10)))",
      "(let ((a 1) (b 2) (c 3)) `(x ,a ,@(list b c) y))",
      "`#(1 ,(+ 1 1) 3)",
      "(letrec* ((x 1) (y (+ x 1))) (+ x y))",
      "(+ (call/cc (lambda (k) 1)) (call/cc (lambda (k) (k 10) 999)))",
      "(dynamic-wind (lambda () 'before) (lambda () 'during) (lambda () 'after))",
      "(define f (case-lambda ((a) (list 'one a)) ((a b) (list 'two a b)) ((a b . rest) (list 'many a b rest)))) (list (f 1) (f 1 2) (f 1 2 3 4))",
      "'(1/2 -3/4 1+2i #u8(1 2 3))",
      "(let-values (((a b) (values 1 2)) ((c) (values 3))) (list a b c))",
      "(let*-values (((a b) (values 1 2)) ((c) (values (+ a b)))) (list a b c))",
      "(define-values (a b) (values 10 20)) (+ a b)",
      "(call-with-values (lambda () (values 1 2 3)) list)",
      %((guard (e (#t (list 'caught (error-object-message e)))) (error "boom"))),
      %((guard (e ((symbol? e) (list 'sym e)) (else (list 'other e))) (raise 'oops))),
      "(+ 1 (guard (e (#t 100)) (car '())))",
      %((define (safe-div a b) (guard (e (#t 'error)) (/ a b))) (list (safe-div 10 2) (safe-div 10 0))),
      %((define-syntax my-list (syntax-rules () ((_ e ...) (list e ...)))) (my-list 1 2 3 4)),
      %((define-syntax swap! (syntax-rules () ((_ a b) (let ((tmp a)) (set! a b) (set! b tmp))))) (define x 1) (define y 2) (swap! x y) (list x y)),
      %((define-syntax my-or2 (syntax-rules () ((_ ) #f) ((_ e) e) ((_ e1 e2 ...) (let ((mor-t e1)) (if mor-t mor-t (my-or2 e2 ...)))))) (list (my-or2) (my-or2 5) (my-or2 #f #f 7) (my-or2 #f #f #f))),
      %((define-syntax my-let-star (syntax-rules () ((_ () body ...) (let () body ...)) ((_ ((n v) rest ...) body ...) (let ((n v)) (my-let-star (rest ...) body ...))))) (my-let-star ((a 1) (b (+ a 1)) (c (+ b 1))) (list a b c))),
      %((define-syntax my-cond (syntax-rules (else) ((_ (else e ...)) (begin e ...)) ((_ (test e ...) clause ...) (if test (begin e ...) (my-cond clause ...))))) (my-cond ((= 1 2) 'a) ((= 1 1) 'b) (else 'c))),
      %((define p (make-parameter 10)) (list (p) (parameterize ((p 20)) (p)) (p))),
      %((define p1 (make-parameter 1)) (define p2 (make-parameter 2)) (parameterize ((p1 100) (p2 200)) (+ (p1) (p2)))),
      "(define pr (delay (begin (+ 1 2)))) (list (force pr) (force pr))",
      %((eval '(+ 1 2 3))),
      "(list 3.14 -2.5 1e10 (/ 1.0 3))",
      %((let-syntax ((double (syntax-rules () ((_ x) (* 2 x))))) (list (double 5) (double 10)))),
      %((define-syntax outer-macro (syntax-rules () ((_ x) (+ x 1)))) (letrec-syntax ((double (syntax-rules () ((_ x) (* 2 (outer-macro x)))))) (double 5))),
      # let-syntax/letrec-syntax scoping edge cases -- the Creme compiler
      # uses a whole-macro-table snapshot/restore (compile-let-syntax!)
      # instead of Crystal's own parent-chained MacroEnv (analyze_let_syntax);
      # these check that's behaviorally equivalent for shadowing an outer
      # macro of the same name (and correctly un-shadowing it afterward),
      # sibling let-syntax forms not leaking into each other, and nested
      # let-syntax shadowing an enclosing let-syntax's own same-named macro.
      %((define-syntax id (syntax-rules () ((_ x) (list 'outer x))))
        (list (id 1) (let-syntax ((id (syntax-rules () ((_ x) (list 'inner x))))) (id 2)) (id 3))),
      %((list (let-syntax ((tag (syntax-rules () ((_ x) (list 'a x))))) (tag 1))
              (let-syntax ((tag (syntax-rules () ((_ x) (list 'b x))))) (tag 2)))),
      %((let-syntax ((tag (syntax-rules () ((_ x) (list 'outer x)))))
          (list (tag 1) (let-syntax ((tag (syntax-rules () ((_ x) (list 'inner x))))) (tag 2)) (tag 3)))),
      "(define (f) (display \"a\") (begin (define y 10)) (+ y 1)) (f)",
      %((let ((x 1)) `(a `(b ,(+ 1 2) ,,x)))),
      %((let ((name 'foo) (val 42)) `(define ,name ,val))),
      %((cond-expand (else 'ok))),
      %((cond-expand ((library (does not exist)) 'no) (r7rs 'yes) (else 'fallback))),
      %((cond-expand (creme 'yes) (else 'no))),
      %((cond-expand ((and creme creme.cr) 'yes) (else 'no))),
      %((cond-expand ((or (library (does not exist)) creme) 'yes) (else 'no))),
      %((import (creme regex)) (regexp-matches? (regexp "a+") "aaa")),
      %((import (only (creme regex) regexp regexp-matches?)) (regexp-matches? (regexp "[0-9]+") "42")),
      "(define (f x) (when (> x 0) (display \"pos \") x)) (list (f 5) (f -5))",
      "(define (f x) (unless (> x 0) (display \"nonpos \") x)) (list (f 5) (f -5))",
      "(define v #(1 2 3)) (vector-ref v 1)",
      "(define bv #u8(1 2 3)) (bytevector-u8-ref bv 2)",
      # Primitive-call fusion: exact arity required (a 3-arg + must NOT
      # fuse, still correct via the variadic builtin).
      "(+ 1 2 3)",
      # Locally shadowed name must NOT fuse (ordinary Call to the shadow).
      "(let ((+ -)) (+ 5 2))",
      # Nested-argument fusable calls -- arguments are themselves calls, not
      # bare variables/literals.
      "(define (foo x) (* x 2)) (define (bar y) (+ y 3)) (+ (foo 4) (bar 5))",
      # Tail-position fusion: arithmetic/comparison (has a *Return variant)
      # and an accessor (doesn't -- base op + explicit Return).
      "(define (f x) (+ x 1)) (f 41)",
      "(define (g x) (< x 10)) (list (g 5) (g 50))",
      "(define (h v) (vector-ref v 0)) (h #(9 8 7))",
      "(define (k p) (car p)) (k (cons 1 2))",
      # Mutator fusion (vector-set!/string-set!), including the
      # dest == object-register case (the call's own dest register is
      # never read, matching typical (begin (vector-set! ...) ) usage).
      "(define v (vector 1 2 3)) (vector-set! v 1 99) v",
      "(define s (make-string 3 #\\a)) (string-set! s 1 #\\z) s",
      "(let ((v (vector 0 0))) (vector-set! v 0 1) (vector-set! v 1 2) v)",
      # A macro expanding to a fusable primitive call must fuse too --
      # no special-casing needed since expansion happens before compile-app!.
      %((define-syntax my-add (syntax-rules () ((_ a b) (+ a b)))) (my-add 3 4)),
      # Direct call fusion (CallGlobal/CallLocal/CallUpval, TailCall*):
      # self-recursive tail call, a non-tail call to another top-level
      # global, a call to a local (let-bound) callable, and a call to an
      # upvalue-captured callable from a closure.
      "(define (count-down n) (if (= n 0) 'done (count-down (- n 1)))) (count-down 100000)",
      "(define (helper x) (* x x)) (define (caller y) (+ (helper y) 1)) (caller 5)",
      "(let ((f (lambda (x) (* x 2)))) (f 21))",
      "(define (make-caller g) (lambda (x) (g x))) ((make-caller (lambda (x) (+ x 1))) 9)",
      # *Imm operand specialization: literal 2nd operand for arithmetic/
      # comparison/eq?/vector-ref/vector-set!, at and just past the Int32
      # boundary (falls back to the base op beyond it, still correct).
      "(- 10 1)",
      "(< 5 2147483647)",
      "(eq? 'x 'y)",
      "(vector-set! (vector 1 2 3) 1 99)",
      "(+ 1 3000000000)",
      "(- 1 3000000000)",
      # *Up operand specialization: a named-let loop closing over an
      # invariant bound used as a comparison's 2nd operand, and a vector
      # captured the same way used as an accessor's 1st (object) operand.
      "(define (sum-to n) (let loop ((i 0) (acc 0)) (if (< i n) (loop (+ i 1) (+ acc i)) acc))) (sum-to 1000)",
      "(define (vsum v) (let ((len (vector-length v))) (let loop ((i 0) (acc 0)) (if (= i len) acc (loop (+ i 1) (+ acc (vector-ref v i))))))) (vsum (vector 1 2 3 4 5))",
      "(define (fill-with! v x) (let loop ((i 0)) (if (< i (vector-length v)) (begin (vector-set! v i x) (loop (+ i 1))) v))) (fill-with! (vector 0 0 0) 7)",
      # Fused compare-and-branch: base/Imm/Up variants used directly as an
      # if-test (both branches), an if with no else clause, unless/when
      # (which desugar through the same peel-not path) with a comparison
      # condition, and a shadowed comparison operator in test position
      # (must NOT fuse, ordinary Call to the shadow).
      "(list (if (< 1 2) 'yes 'no) (if (< 2 1) 'yes 'no))",
      "(if (< 10 5) 'unreachable)",
      "(define (f x) (unless (< x 0) 'nonneg)) (list (f 5) (f -5))",
      "(define (f x) (when (< x 0) 'neg)) (list (f 5) (f -5))",
      "(define (f n) (let loop ((i 0)) (if (< i n) (loop (+ i 1)) i))) (f 50)",
      "(define (g v) (let ((n (vector-length v))) (let loop ((i 0)) (if (= i n) 'done (loop (+ i 1)))))) (g (vector 1 2 3))",
      "(let ((< >)) (list (if (< 1 2) 'yes 'no) (if (< 2 1) 'yes 'no)))",
      "(eq? 'a 'a)",
      # Fast in-place tail-call argument compilation: a genuinely unchanged
      # pass-through argument (exercises Move-elision), a tail call whose
      # arguments swap two registers (exercises the scratch/deferred-Move
      # hazard path -- an even number of swaps must return to the original
      # values), and a closure created earlier in a loop's own body that
      # captures the loop variable -- each snapshot must see the value AT
      # THE TIME it was created, not whatever the loop variable's register
      # holds after later iterations directly overwrote it (the core new
      # safety-relevant case for fcomp-captured-regs).
      "(define (count-with-limit i limit) (if (= i limit) 'done (count-with-limit (+ i 1) limit))) (count-with-limit 0 1000)",
      "(define (swap-loop n a b) (if (= n 0) (list a b) (swap-loop (- n 1) b a))) (swap-loop 4 1 2)",
      # leaf-expr? recognizes a fusable-primitive call (whose own
      # arguments are all leaves too) as a leaf, mirroring
      # bytecode_compiler.cr's own recursive leaf_node? -- found by
      # diffing disassembled bytecode between the two compilers: sum-vec
      # above (its named-let compares its own parameter `i` directly
      # against the compound `(vector-length v)`) used to always copy `i`
      # into a fresh register first, treating ANY compound expression as
      # unsafe to reorder around, unlike native; making leaf-expr?
      # recursive fixed that. But that ALSO widens which tail calls take
      # the fast in-place-argument path (every-leaf?), which depends on
      # arg-reads-register? correctly detecting a register read INSIDE a
      # compound leaf argument, not just a bare symbol -- this case
      # exercises exactly that: a tail call that swaps two parameters via
      # compound (fusable-call) expressions rather than bare variables,
      # which MUST still take the deferred-scratch-register path despite
      # each argument being compound, not a bare symbol -- silently
      # reading the WRONG (already-overwritten) value if
      # arg-reads-register? didn't recurse into it.
      "(define (swap-loop-compound n a b) (if (= n 0) (list a b) (swap-loop-compound (- n 1) (+ b 0) (+ a 0)))) (swap-loop-compound 4 1 2)",
      "(define (loop-with-closure n) (let loop ((i 0) (snapshots '())) (if (= i n) (map (lambda (f) (f)) (reverse snapshots)) (let ((snap (lambda () i))) (loop (+ i 1) (cons snap snapshots)))))) (loop-with-closure 5)",
      # Scope-based register reclaim: several sequential lets/statements in
      # one body (register count must not keep growing across siblings --
      # this only affects footprint, not output, so this is really just a
      # correctness-after-reclaim check), a deeply-nested arithmetic
      # expression inside a loop (Step 2's per-op reclaim across many
      # iterations), and case-lambda/parameterize (Step 3's reclaim points).
      "(define (f) (let ((a 1)) a) (let ((b 2)) b) (let ((c 3)) c) (let ((d 4)) d) 'done) (f)",
      "(define (deep n) (let loop ((i 0) (acc 0)) (if (= i n) acc (loop (+ i 1) (+ acc (* (+ i 1) (- i 1) (+ i i))))))) (deep 200)",
      "(define f (case-lambda ((a) (list 'one a)) ((a b) (+ a b)) ((a b . rest) (list a b rest)))) (list (f 1) (f 1 2) (f 1 2 3 4))",
      "(define p (make-parameter 1)) (define (g) (parameterize ((p 10)) (+ (p) (p)))) (list (g) (g) (p))",
      # Regression: hoist-internal-defines (modules/creme/compiler/
      # compiler.sld) used to bucket a body's own forms into "all
      # defines" (folded into letrec*'s bindings, evaluated before
      # anything else) and "everything else" (the body, run after) --
      # silently reordering a body that interleaves defines and plain
      # expressions. `found`'s own initializer used to run BEFORE
      # register! (since it was bucketed as a "definition", moved ahead
      # of the body), even though `found`'s own `define` appears
      # textually after register! in the source. See that function's
      # own doc comment for the full explanation and fix (letrec* now
      # only pre-declares names; each define is replaced in place, in
      # original order, with an ordinary set!).
      "(define registry '()) (define (register! x) (set! registry (cons x registry))) (define (f) (define worker 42) (register! worker) (define found registry) found) (f)",
      # Internal (define ...) hoisted into a letrec* in every body position
      # that introduces a scope, not just lambda/let bodies directly --
      # cond clauses (else and plain), case clauses (desugars into cond),
      # and when/unless bodies.
      "(define (f x) (cond (else (define y (* x 2)) (+ y 1)))) (f 5)",
      "(define (f x) (cond ((> x 0) (define y (* x 2)) (+ y 1)) (else 'neg))) (list (f 5) (f -5))",
      "(define (f n) (case n ((1 2 3) (define y 'small) y) (else (define y 'large) y))) (list (f 2) (f 99))",
      "(define (f x) (when (> x 0) (define y (* x 10)) y)) (list (f 5) (f -5))",
      "(define (f x) (unless (> x 0) (define y (* x 10)) y)) (list (f 5) (f -5))",
      # Internal define-values and internal define-record-type, both
      # hoisted through the same letrec* mechanism as plain internal
      # defines -- exercised in a lambda body, a let body, and a cond
      # clause body (so a rest-arg define-values and a mutable record
      # field both get covered).
      "(define (f) (define-values (a b) (values 1 2)) (+ a b)) (f)",
      "(define (f) (define-values (a . rest) (values 1 2 3)) (list a rest)) (f)",
      "(let () (define-values (a b c) (values 1 2 3)) (* a b c))",
      %((define (f) (define-record-type <pt> (make-pt x y) pt? (x pt-x set-pt-x!) (y pt-y)) (define p (make-pt 3 4)) (set-pt-x! p 9) (list (pt? p) (pt-x p) (pt-y p))) (f)),
      %((define (f flag) (cond (flag (define-record-type <box> (make-box v) box? (v box-v)) (box-v (make-box 42))) (else 'no))) (list (f #t) (f #f))),
    ].each { |src| check(interp, src) }
  end

  # A closure capturing a let-bound local, called AFTER several more
  # sibling scopes have run and popped, must still see the value at
  # capture time, not whatever a later sibling scope's own local happens
  # to reuse that register for. This USED to be a genuine bug in the real
  # Crystal BytecodeCompiler too (FunctionCompiler#pop_scope rolled
  # next_reg back unconditionally, never consulting captured_registers,
  # and upvalues are only closed at frame-return/tail-call time per
  # vm.cr's close_upvalues call sites, never at ordinary lexical scope
  # exit) -- now fixed there too, generally (pop_scope/reclaim_to#floor_
  # respecting_captures applies at every scope exit and mid-scope
  # reclaim, not just one narrow call site -- doing so also required
  # fixing compile_app's two general-path branches to reserve every call
  # argument's register up front, see bytecode_compiler.cr's own comment
  # there for why) -- see spec/scheme/compile/bytecode_vm_spec.cr's own
  # "protects a captured local's register"/"keeps later call arguments
  # in their own registers" cases, which exercise BytecodeCompiler
  # directly and are the real regression tests for this; this one still
  # just checks the self-hosted compiler's own, independent
  # implementation, which never had either bug.
  it "protects a captured local's register across later sibling scopes" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    load_toolchain(interp)
    src = <<-SCM
    (define (h)
      (define snap #f)
      (let ((x 42)) (set! snap (lambda () x)))
      (let ((y 1)) (set! y (+ y 1)))
      (let ((z 2)) (set! z (* z 2)))
      (let ((w 3)) (set! w (- w 1)))
      (snap))
    (h)
    SCM
    bootstrap_eval(interp, src).should eq("42")
  end

  it "compiles a local defmacro (not define-syntax/syntax-rules) matching native evaluation" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    load_toolchain(interp)
    [
      %((defmacro my-swap! (a b) (list 'let (list (list 'tmp a)) (list 'set! a b) (list 'set! b 'tmp))) (define x 1) (define y 2) (my-swap! x y) (list x y)),
      %((defmacro my-list-of (n . items) (cons 'list items)) (my-list-of 3 1 2 3)),
      %((defmacro my-when (test . body) (list 'if test (cons 'begin body))) (list (my-when (> 2 1) 'yes) (my-when (> 1 2) 'yes))),
    ].each { |src| check(interp, src) }
  end

  # (creme dao)'s define-dao is a defmacro EXPORTED from a pure-Scheme,
  # file-based library (modules/creme/dao.sld) -- exercises the self-hosted
  # library loader (ensure-libraries-loaded!) end to end: recursively
  # loading dao.sld's own (creme sxql)/(creme sql) dependencies, compiling
  # +running its (begin ...) body (which registers define-dao into
  # macro-table via compile-defmacro!, the same as a textually-local one),
  # then successfully expanding+compiling a real define-dao use. This is
  # the exact pattern that made cvm's own compiler mode abort with "unbound
  # variable: todo" before this support existed (cvm's expand-if-macro is a
  # permanent stub, and cvm's import! is a permanent no-op -- neither
  # applies here since this test runs the bootstrap compiler under the
  # real Crystal interpreter, but the SAME self-hosted code path is what
  # makes it also work correctly under cvm).
  it "loads a defmacro-exporting pure-Scheme library (creme dao) via the self-hosted loader" do
    src = <<-SCM
    (import (scheme base) (creme sql) (creme dao))
    (define conn (sql-open ":memory:"))
    (define-dao todo conn
      (id integer primary-key auto-increment)
      (title text not-null)
      (done bool not-null (default #f)))
    (todo-create! 'title "hello" 'done #f)
    (define result (todo-all))
    (sql-close conn)
    result
    SCM

    # native_eval's own shared Interpreter has no library_search_path, so
    # (creme dao) -- a file-based library -- can't be found through it;
    # same workaround the existing sxql-select! test above already uses.
    native = Creme::Interpreter.new(library_search_path: ["./modules"])
    native_result = Creme.run_source(native, src).write_string

    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    load_toolchain(interp)
    interp.global.define("dao-test-source", Creme::SchemeStr.new(src))
    bootstrap_result = Creme.run_source(interp, "(load-chunk-bytes (compile-source-to-bytes dao-test-source))").write_string

    bootstrap_result.should eq(native_result)
  end

  it "suppresses fusion after a top-level redefinition of a fusable primitive" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    load_toolchain(interp)
    check(interp, "(define (my-plus a b) (list 'sum a b)) (define + my-plus) (+ 1 2)")
  end

  it "suppresses fusion after a set!-redefinition of a fusable primitive" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    load_toolchain(interp)
    check(interp, "(define orig-car car) (set! car (lambda (p) (list 'wrapped (orig-car p)))) (car (cons 1 2))")
  end

  it "expands an imported defmacro (sxql-select!) matching native evaluation" do
    src = <<-SCM
    (import (creme sql) (creme sxql))
    (define conn (sql-open ":memory:"))
    (sql-execute conn "CREATE TABLE sale (region TEXT, amount REAL)")
    (sql-execute conn "INSERT INTO sale (region, amount) VALUES ('north', 120.0)")
    (sql-execute conn "INSERT INTO sale (region, amount) VALUES ('north', 80.0)")
    (sql-execute conn "INSERT INTO sale (region, amount) VALUES ('south', 45.0)")
    (define result
      (map (lambda (row) (cdr (assoc ':amount row)))
           (sxql-select! conn (:amount)
             (from :sale)
             (where (:= :region "north"))
             (order-by (:desc :amount)))))
    (sql-close conn)
    result
    SCM

    native = Creme::Interpreter.new(library_search_path: ["./modules"])
    native_result = Creme.run_source(native, src).write_string

    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    load_toolchain(interp)
    interp.global.define("sxql-test-source", Creme::SchemeStr.new(src))
    bootstrap_result = Creme.run_source(interp, "(load-chunk-bytes (compile-source-to-bytes sxql-test-source))").write_string

    bootstrap_result.should eq(native_result)
  end

  it "honors a prefix import-set filter against a pure-Scheme file-based library" do
    src = %((import (prefix (creme extra) extra:)) (extra:filter odd? '(1 2 3 4 5)))

    native = Creme::Interpreter.new(library_search_path: ["./modules"])
    native_result = Creme.run_source(native, src).write_string

    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    load_toolchain(interp)
    interp.global.define("import-prefix-test-source", Creme::SchemeStr.new(src))
    bootstrap_result = Creme.run_source(interp, "(load-chunk-bytes (compile-source-to-bytes import-prefix-test-source))").write_string

    bootstrap_result.should eq(native_result)
  end

  it "honors a rename import-set filter against a pure-Scheme file-based library" do
    src = %((import (rename (creme extra) (filter my-filter))) (my-filter odd? '(1 2 3 4 5)))

    native = Creme::Interpreter.new(library_search_path: ["./modules"])
    native_result = Creme.run_source(native, src).write_string

    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    load_toolchain(interp)
    interp.global.define("import-rename-test-source", Creme::SchemeStr.new(src))
    bootstrap_result = Creme.run_source(interp, "(load-chunk-bytes (compile-source-to-bytes import-rename-test-source))").write_string

    bootstrap_result.should eq(native_result)
  end

  it "rejects a non-top-level import" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    load_toolchain(interp)
    interp.global.define("bad-import-source", Creme::SchemeStr.new("(define (f) (import (creme regex)) 1) (f)"))
    expect_raises(Creme::SchemeUserError, /only supported at the top level/) do
      Creme.run_source(interp, "(compile-source-to-bytes bad-import-source)")
    end
  end

  # compile-source-to-bytes compiles a WHOLE program up front, before any
  # of it runs -- so compile-import!'s eager compile-time import! (there
  # only to make an import's exports visible to a LATER macro use) used to
  # raise and abort the entire compile when a library genuinely doesn't
  # exist yet at compile time, as here: an earlier ordinary form writes
  # the library file this later (import ...) then loads. That eager call
  # is now guarded/swallowed; the runtime import! call already
  # unconditionally emitted into the compiled program does the real work
  # once its turn comes, in the correct (post-file-write) order -- exactly
  # like examples/26-import-generated-library.scm, which this mirrors.
  it "imports a library file written by an earlier form in the same program" do
    src = <<-SCM
    (import (creme file))
    (file-write "./modules/compiler-spec-generated.sld"
      "(define-library (compiler-spec-generated)
         (export greet)
         (import (scheme base))
         (begin (define (greet name) (string-append \\"hi \\" name))))")
    (import (compiler-spec-generated))
    (define result (greet "Ada"))
    (delete-file "./modules/compiler-spec-generated.sld")
    result
    SCM

    # Needs its own library_search_path on BOTH sides (unlike check()'s
    # shared native_eval helper, which has none) so the generated library
    # under ./modules is actually resolvable -- same reasoning as the dao/
    # sxql tests above.
    native = Creme::Interpreter.new(library_search_path: ["./modules"])
    native_result = Creme.run_source(native, src).write_string

    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    load_toolchain(interp)
    interp.global.define("generated-library-test-source", Creme::SchemeStr.new(src))
    bootstrap_result = Creme.run_source(interp, "(load-chunk-bytes (compile-source-to-bytes generated-library-test-source))").write_string

    bootstrap_result.should eq(native_result)
  end

  it "properly tail-calls a named-let loop over 200000 iterations without overflowing" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    load_toolchain(interp)
    src = "(let loop ((i 0) (acc 0)) (if (= i 200000) acc (loop (+ i 1) (+ acc i))))"
    check(interp, src)
  end

  it "self-compiles (creme compiler reader) and produces a working read-program" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    load_toolchain(interp)

    body_source = library_body_source("modules/creme/compiler/reader.sld")
    interp.global.define("reader-source-to-compile", Creme::SchemeStr.new(body_source))
    Creme.run_source(interp, "(load-chunk-bytes (compile-source-to-bytes reader-source-to-compile))")

    test_source = %((define (fact n) (if (= n 0) 1 (* n (fact (- n 1))))) (display (fact 5)) (newline) (define v #(1 2 3)) (write v))
    interp.global.define("nested-test-source", Creme::SchemeStr.new(test_source))
    result = Creme.run_source(interp, <<-SCM)
    (let ((forms (read-program nested-test-source))
          (out (open-output-string)))
      (for-each (lambda (f) (write f out) (write-char #\\newline out)) forms)
      (get-output-string out))
    SCM

    expected = Creme::Reader.read_all(test_source).map(&.write_string).join("\n") + "\n"
    result.as(Creme::SchemeStr).value.should eq(expected)
  end

  it "self-compiles (creme compiler compiler) and the result compiles a small program correctly" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    load_toolchain(interp)

    body_source = library_body_source("modules/creme/compiler/compiler.sld")
    interp.global.define("compiler-source-to-compile", Creme::SchemeStr.new(body_source))
    Creme.run_source(interp, "(load-chunk-bytes (compile-source-to-bytes compiler-source-to-compile))")

    # `compile-source-to-bytes` is now the SELF-COMPILED version's own
    # definition -- use it to compile a small program, same verification
    # loop as everywhere else in this file.
    test_source = "(define (fact n) (if (= n 0) 1 (* n (fact (- n 1))))) (fact 6)"
    interp.global.define("nested-program-source", Creme::SchemeStr.new(test_source))
    result = Creme.run_source(interp, "(load-chunk-bytes (compile-source-to-bytes nested-program-source))")
    result.write_string.should eq(native_eval(test_source))
  end
end
