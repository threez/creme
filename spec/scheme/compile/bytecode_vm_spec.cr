require "../../spec_helper"

# The register VM (BytecodeCompiler + VM, eval/vm.cr) is not wired into
# Creme.run_source/run_file yet (see feature/bytecode-vm's phased plan) — it
# compiles/runs its own fresh Interpreter's forms directly, bypassing the
# tree-walker entirely, so these specs exercise it as its own independent
# evaluator. Uses BytecodeCompiler.run_program's per-form analyze-compile-run
# loop (mirroring Creme.run_source), not a single upfront compile of every
# form — required for define-syntax/import to correctly affect later forms'
# analysis, exactly like the tree-walker's own per-form loop.
private def vm_run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  forms = Creme::Reader.read_all(src)
  Creme::BytecodeCompiler.run_program(interp, forms)
end

private def w(src : String) : String
  vm_run(src).write_string
end

describe "BytecodeCompiler + VM" do
  describe "literals, arithmetic, control flow" do
    it "evaluates arithmetic and comparisons" do
      w("(+ 1 2)").should eq("3")
      w("(* 6 7)").should eq("42")
      w("(< 1 2)").should eq("#t")
      w("(>= 2 3)").should eq("#f")
    end

    it "evaluates if/begin/and/or/when/unless" do
      w("(if (< 1 2) 'yes 'no)").should eq("yes")
      w("(begin 1 2 3)").should eq("3")
      w("(and 1 2 3)").should eq("3")
      w("(and 1 #f 3)").should eq("#f")
      w("(or #f #f 5)").should eq("5")
      w("(when (> 2 1) 'a 'b)").should eq("b")
      w("(unless (> 2 1) 'a 'b)").should eq("()")
    end

    it "evaluates let/let*/letrec" do
      w("(let ((a 1) (b 2)) (+ a b))").should eq("3")
      w("(let* ((a 1) (b (+ a 1))) (+ a b))").should eq("3")
      w("(letrec ((even? (lambda (n) (if (= n 0) #t (odd? (- n 1)))))" \
        "         (odd? (lambda (n) (if (= n 0) #f (even? (- n 1))))))" \
        "  (even? 10))").should eq("#t")
    end
  end

  describe "functions, recursion, tail calls" do
    it "computes non-tail recursion (fact)" do
      w("(define (fact n) (if (< n 2) 1 (* n (fact (- n 1))))) (fact 10)").should eq("3628800")
    end

    it "computes non-tail recursion (fib)" do
      w("(define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (fib 15)").should eq("610")
    end

    it "handles a large self-tail-recursive named-let loop without stack growth" do
      w("(let loop ((i 0) (acc 0)) (if (= i 1000000) acc (loop (+ i 1) (+ acc i))))")
        .should eq("499999500000")
    end

    it "evaluates a counted loop's carried variables simultaneously, not sequentially" do
      # `a`'s step reads `b`'s OLD value (and vice versa isn't true here) —
      # the counted-loop lowering's direct-write optimization (bytecode_
      # compiler.cr's try_compile_counted_loop) must still evaluate every
      # step expression against the PRE-iteration bindings, exactly like a
      # real tail call would, not let an early direct write into `a`'s own
      # register affect what `b`'s (or a later iteration's `a`'s) step sees.
      # a: 0,1,3,7,15 (a' = a+b); b: 1,2,4,8,16 (b' = b*2) after 4 steps.
      w("(let loop ((i 0) (a 0) (b 1)) (if (= i 4) (list a b) (loop (+ i 1) (+ a b) (* b 2))))")
        .should eq("(15 16)")
    end

    it "handles mutually-referencing carried variables (neither is direct-write-safe)" do
      # Both a's and b's step expressions read the OTHER's old value (a' =
      # a+b, b' = a — b trails one step behind a), so neither may be written
      # directly — both must go through a temp register, exactly like the
      # pre-optimization path always did: (0,1)->(1,0)->(1,1)->(2,1).
      w("(let loop ((i 0) (a 0) (b 1)) (if (= i 3) (list a b) (loop (+ i 1) (+ a b) a)))")
        .should eq("(2 1)")
    end

    it "handles rest args" do
      w("(define (f . xs) xs) (f 1 2 3)").should eq("(1 2 3)")
      w("(define (f a . rest) (list a rest)) (f 1 2 3)").should eq("(1 (2 3))")
    end
  end

  describe "closures and upvalues" do
    it "mutates a shared upvalue across calls" do
      w("(define (make-counter) (let ((n 0)) (lambda () (set! n (+ n 1)) n)))" \
        "(define c (make-counter)) (c) (c) (c)").should eq("3")
    end

    it "captures each loop iteration's own value independently (not aliased)" do
      w("(define (make-adders n)" \
        "  (let loop ((i 0) (acc '()))" \
        "    (if (= i n) acc (loop (+ i 1) (cons (lambda (x) (+ x i)) acc)))))" \
        "(define adders (make-adders 3))" \
        "(map (lambda (f) (f 100)) adders)").should eq("(102 101 100)")
    end

    # A lambda literal with ZERO captured upvalues (no free variables at
    # all) is re-evaluated to an identical result every time — R7RS never
    # distinguishes separate evaluations of such a literal (eq?-identity
    # across them is unspecified either way), so VM#make_closure memoizes
    # one instance per (owning closure instance, proto slot) instead of
    # allocating a fresh, immediately-identical object on every evaluation
    # — the actual win being hot loops that evaluate a lambda literal once
    # per iteration (e.g. a default-value thunk argument).
    it "memoizes a zero-upvalue lambda literal evaluated repeatedly inside a tail-recursive loop" do
      w("(define (make-thunks n)" \
        "  (let loop ((i 0) (acc '()))" \
        "    (if (= i n) acc (loop (+ i 1) (cons (lambda () 42) acc)))))" \
        "(define thunks (make-thunks 5))" \
        "(list (map (lambda (t) (eq? t (car thunks))) thunks) (map (lambda (t) (t)) thunks))")
        .should eq("((#t #t #t #t #t) (42 42 42 42 42))")
    end

    # A top-level `define`d function is itself a single, stable closure
    # instance invoked repeatedly (not re-created per call), so a
    # zero-upvalue lambda nested directly inside one is legitimately the
    # SAME cached instance across separate top-level calls to it — this
    # spec instead forces two GENUINELY separate instances of the
    # enclosing (middle) closure (by giving it a real, non-zero upvalue,
    # so IT can't be memoized and gets freshly allocated per make-middle
    # call) to confirm each such instance gets its own independent memo,
    # not one shared globally by the nested lambda's Chunk/proto alone.
    it "gives each separate instance of the enclosing closure its own independent memo" do
      w("(define (make-middle tag)" \
        "  (lambda ()" \
        "    (if (< tag 0) 'unreachable #f)" \
        "    (lambda () 'x)))" \
        "(define middle1 (make-middle 1))" \
        "(define middle2 (make-middle 2))" \
        "(list (eq? (middle1) (middle1)) (eq? (middle1) (middle2)))")
        .should eq("(#t #f)")
    end

    it "still captures the current value correctly for a lambda literal with real (non-zero) upvalues, unaffected by memoization" do
      w("(define (make-adders n)" \
        "  (let loop ((i 0) (acc '()))" \
        "    (if (= i n) acc (loop (+ i 1) (cons (lambda () i) acc)))))" \
        "(map (lambda (f) (f)) (make-adders 3))").should eq("(2 1 0)")
    end

    it "memoizes a zero-upvalue clause inside case-lambda the same way" do
      w("(define f (case-lambda (() 'none) ((x) (lambda () 'inner))))" \
        "(eq? (f 1) (f 2))").should eq("#t")
    end

    # Regression test for a genuine bug (not a deliberate cut): a closure
    # capturing a let-bound local, called AFTER several more SIBLING
    # scopes have run and popped, used to see whatever the LAST sibling
    # scope's own local happened to reuse that register for (2) instead
    # of the value at capture time (42). FunctionCompiler#pop_scope
    # rolled next_reg back to saved_next_reg unconditionally, never
    # consulting captured_registers — and upvalues are only closed at
    # frame-return/tail-call time (vm.cr's close_upvalues call sites),
    # never at ordinary lexical scope exit — so a later sibling scope's
    # own local silently landed in the same register, overwriting the
    # captured local's still-open upvalue. Fixed via pop_scope/
    # reclaim_to#floor_respecting_captures, applied generally (every
    # scope exit and every mid-scope reclaim, not just one narrow call
    # site) — this initially broke compile_app's two general-path
    # branches (their per-argument alloc_reg calls relied on "nothing
    # shrinks next_reg between these allocations, so they stay
    # contiguous", which a non-leaf argument's own captured-register
    # floor could violate), fixed at the root by having both branches
    # reserve every argument's register up front, in one batch, before
    # compiling any argument's own expression — mirroring self-hosted
    # compiler.sld's compile-ordinary-app!, which already did this and
    # was never vulnerable to begin with.
    it "protects a captured local's register across later sibling scopes" do
      w("(define (h)" \
        "  (define snap #f)" \
        "  (let ((x 42)) (set! snap (lambda () x)))" \
        "  (let ((y 1)) (set! y (+ y 1)))" \
        "  (let ((z 2)) (set! z (* z 2)))" \
        "  (let ((w 3)) (set! w (- w 1)))" \
        "  (snap))" \
        "(h)").should eq("42")
    end

    # Regression test for the OTHER genuine bug the fix above initially
    # introduced (then fixed at the root — see this describe block's own
    # header): compile_app's two general-path branches used to allocate
    # one register per call argument via repeated top-level alloc_reg
    # calls, one argument at a time, relying on "nothing shrinks next_reg
    # between these allocations, so they stay contiguous". A non-leaf
    # FIRST argument (here, a self-recursive named-let, whose own `loop`
    # binding is captured as an upvalue by its own body) used to leave
    # next_reg higher than expected once ITS OWN scope popped (correctly
    # protecting the captured register) — shifting where the SECOND and
    # THIRD arguments landed, one slot later than the Call/TailCall op
    # expected, so the 3rd argument (`name`) was never actually written
    # where the op reads it, and the op instead read the still-live
    # closure register in its place. Fixed by reserving every argument's
    # register up front, in one batch, before compiling any argument's
    # own expression (see bytecode_compiler.cr's compile_app).
    it "keeps later call arguments in their own registers when an earlier, non-leaf argument captures one internally" do
      w(%((define (full-name n names)
             (string-append
               (let loop ((names names))
                 (if (null? (cdr names)) (car names) (string-append (car names) " > " (loop (cdr names)))))
               " -- "
               n))
           (full-name "leaf" (list "a" "b" "c")))).should eq(%("a > b > c -- leaf"))
    end
  end

  describe "vectors, strings, bytevectors (fused prim ops)" do
    it "vector-ref/vector-set!/vector-length" do
      w("(define v (vector 1 2 3)) (vector-set! v 1 99) (vector-ref v 1)").should eq("99")
      w("(vector-length (vector 1 2 3))").should eq("3")
    end

    it "string-ref/string-set!" do
      w("(let ((s (make-string 3 #\\a))) (string-set! s 1 #\\z) s)").should eq("\"aza\"")
    end

    it "bytevector-u8-ref/bytevector-u8-set!" do
      w("(let ((b (make-bytevector 2))) (bytevector-u8-set! b 0 42) (bytevector-u8-ref b 0))").should eq("42")
    end
  end

  describe "cons/not/null?/pair?/eq? (fused prim ops)" do
    it "computes correctly" do
      w("(cons 1 2)").should eq("(1 . 2)")
      w("(not #f)").should eq("#t")
      w("(not 5)").should eq("#f")
      w("(null? '())").should eq("#t")
      w("(null? 5)").should eq("#f")
      w("(pair? (cons 1 2))").should eq("#t")
      w("(pair? '())").should eq("#f")
      w("(eq? 'x 'x)").should eq("#t")
      w("(eq? 'x 'y)").should eq("#f")
    end
  end

  # A bare local prim operand can alias its own register (skipping a Move)
  # only when nothing evaluated after it mutates that local — see
  # BytecodeCompiler#leaf_node?/local_register_of?. These pin the evaluation
  # order the elision must preserve, in both the safe (alias) and unsafe
  # (must-snapshot) directions.
  describe "prim operand Move-elision preserves left-to-right evaluation" do
    it "aliases a bare local when its suffix is side-effect-free" do
      # `col` is the last operand of `(= (car x) col)` — nothing runs after
      # it, so it aliases r0 directly; result is still correct.
      w("(let ((x '(9 9)) (col 3)) (= (car x) col))").should eq("#f")
      w("(let ((x '(3 9)) (col 3)) (= (car x) col))").should eq("#t")
      # A pure prim sibling (`(* c 2)`) can't mutate `n`, so `n` aliases too.
      w("(let ((n 10) (c 2)) (- n (* c 2)))").should eq("6")
    end

    it "snapshots a bare local when a later sibling can mutate it" do
      # `(begin (set! b 100) 2)` buried in a prim arg makes that whole prim
      # non-leaf, so `b` (the 1st operand) must be read BEFORE it: 7 - 2 = 5.
      w("(let ((b 7)) (- b (* (begin (set! b 100) 2) 1)))").should eq("5")
      # A call sibling likewise forces a snapshot: 5 - 2 = 3, not 99 - 2.
      w("(let ((d 5)) (define (bump!) (set! d 99) 1) (- d (* (bump!) 2)))").should eq("3")
    end
  end

  # compile_app's tail-call optimization (compile_tail_call_args_in_place):
  # a tail call whose arguments are all leaf_node? compiles them directly
  # into registers 0..n-1 instead of a floating anchor, so a pass-through
  # argument needs no Move at all. Each case below pins down a specific
  # hazard the implementation has to get right.
  describe "tail-call argument register reuse" do
    it "passes an accumulator through unchanged across many iterations" do
      # `acc` is a bare pass-through (no Move needed under the
      # optimization) — many iterations so a corrupted register would show.
      w("(let loop ((i 0) (acc 'ok)) (if (= i 1000) acc (loop (+ i 1) acc)))").should eq("ok")
    end

    it "handles a register swap between two accumulators" do
      # Forces the hazard/scratch path: writing the new `a` directly would
      # clobber the value the new `b` still needs to read.
      w("(let loop ((n 5) (a 1) (b 2)) (if (= n 0) (list a b) (loop (- n 1) b a)))")
        .should eq("(2 1)")
    end

    it "preserves left-to-right evaluation order for tail-call arguments" do
      w("(define log '())" \
        "(define (tag! x) (set! log (cons x log)) x)" \
        "(let loop ((i 0) (a 0) (b 0))" \
        "  (if (= i 2) (reverse log) (loop (+ i 1) (tag! 'first) (tag! 'second))))")
        .should eq("(first second first second)")
    end

    it "falls back safely when an argument creates a closure over the loop's own state" do
      # `acc` at the time of the CURRENT iteration must be captured by each
      # closure — an unsafe direct-write would corrupt earlier closures'
      # captured value before they ever run.
      w("(define (make-adders n)" \
        "  (let loop ((i 0) (acc '()))" \
        "    (if (= i n) acc (loop (+ i 1) (cons (lambda (x) (+ x i)) acc)))))" \
        "(map (lambda (f) (f 100)) (make-adders 3))").should eq("(102 101 100)")
    end

    it "relocates a :local callee whose own register coincides with an argument target" do
      # `f` (the callee) lives in the very register argument 0 would
      # otherwise target directly — the callee's value must be read before
      # that register gets overwritten.
      w("((lambda (f) (f 100)) (lambda (x) (+ x 1)))").should eq("101")
    end

    it "does not corrupt an earlier closure's still-open upvalue into a target register" do
      # `b` is captured by `f`'s own closure (created before the tail call)
      # as an open upvalue into the very register argument 1 would
      # otherwise target directly.
      w("(let ((b 41)) (let ((f (lambda (x) (+ b x)))) (f 1)))").should eq("42")
    end
  end

  describe "cond" do
    it "picks the first matching clause, supports else/=>/empty-body" do
      w("(cond ((= 1 2) 'a) ((= 1 1) 'b) (else 'c))").should eq("b")
      w("(cond (#f 'a) (else 'c))").should eq("c")
      w("(cond ((assv 1 '((1 . one) (2 . two))) => cdr) (else 'none))").should eq("one")
      w("(cond (#f 'a))").should eq("()")
      w("(cond (42))").should eq("42") # bare test value, no body
    end
  end

  describe "case" do
    it "matches via eqv?, supports else/=>/empty-body" do
      w("(case (* 2 3) ((2 3 5 7) 'prime) ((1 4 6 8 9) 'composite) (else 'unknown))").should eq("composite")
      w("(case (car '(c d)) ((a e i o u) 'vowel) ((w y) 'semivowel)" \
        "  (else => (lambda (x) (list 'other x))))").should eq("(other c)")
      w("(case 99 ((1 2) 'a))").should eq("()") # no match, no else -> NIL
      w("(case 1 ((1) ))").should eq("()")      # bare-datum match, empty body -> NIL (not the key)
    end

    # 8+ total datums, all hashable (ints here) -- exercises
    # BytecodeCompiler#compile_case_hash_dispatch/Op::CaseDispatch instead of
    # the linear CaseMatch/TestFalse chain (see hashable_case?'s threshold).
    it "hash-dispatches large all-literal case forms (Op::CaseDispatch)" do
      big = <<-SCM
        (case n
          ((0 1) 'zero-or-one)
          ((2 3) 'two-or-three)
          ((4 5) 'four-or-five)
          ((6 7) 'six-or-seven)
          (else 'other))
      SCM
      w("(define n 0) #{big}").should eq("zero-or-one")  # match on first clause
      w("(define n 7) #{big}").should eq("six-or-seven") # match on last clause
      w("(define n 42) #{big}").should eq("other")       # no match, has else

      no_else = <<-SCM
        (case n
          ((0 1) 'a) ((2 3) 'b) ((4 5) 'c) ((6 7) 'd))
      SCM
      w("(define n 42) #{no_else}").should eq("()") # no match, no else -> NIL
    end

    it "hash-dispatch: first clause wins on a duplicate datum across clauses" do
      w(<<-SCM
        (case 1
          ((1 2) 'first) ((1 3) 'second) ((4 5) 'x) ((6 7) 'y) (else 'z))
        SCM
      ).should eq("first")
    end

    it "hash-dispatch: distinguishes datum types that could otherwise collide" do
      w(<<-SCM
        (case #\\a
          ((0 1) 'int-zero-or-one)
          ((#\\a #\\b) 'char-a-or-b)
          ((foo bar) 'sym)
          ((#t #f) 'bool)
          (else 'none))
        SCM
      ).should eq("char-a-or-b")
      w(<<-SCM
        (case #f
          ((0 1) 'int-zero-or-one)
          ((#\\a #\\b) 'char-a-or-b)
          ((foo bar) 'sym)
          ((#t #f) 'bool)
          (else 'none))
        SCM
      ).should eq("bool")
    end

    it "falls back to the linear path when else isn't last" do
      w(<<-SCM
        (case 9
          ((0 1) 'a) (else 'else-first) ((2 3) 'b) ((4 5) 'c) ((6 7) 'd))
        SCM
      ).should eq("else-first")
    end

    it "falls back to the linear path for non-hashable datum types" do
      w(<<-SCM
        (case 1.5
          ((0 1) 'a) ((2 3) 'b) ((1.5 2.5) 'floats) ((4 5) 'c) (else 'z))
        SCM
      ).should eq("floats")
    end

    it "falls back to the linear path for a malformed clause" do
      expect_raises(Creme::SchemeRuntimeError, /empty clause/) do
        vm_run(<<-SCM
          (case 99
            ((0 1) 'a) ((2 3) 'b) ((4 5) 'c) ((6 7) 'd) ())
          SCM
        )
      end
    end
  end

  describe "case-lambda" do
    it "dispatches by argument count, including a rest clause" do
      w("(define f (case-lambda" \
        "            (() 'zero)" \
        "            ((a) (list 'one a))" \
        "            ((a b) (list 'two a b))" \
        "            ((a . rest) (list 'many a rest))))" \
        "(list (f) (f 1) (f 1 2) (f 1 2 3 4))")
        .should eq("(zero (one 1) (two 1 2) (many 1 (2 3 4)))")
    end
  end

  describe "multiple values" do
    it "define-values, including a rest binding" do
      w("(define-values (q r) (values 3 4)) (list q r)").should eq("(3 4)")
      w("(define-values (a . rest) (values 1 2 3)) (list a rest)").should eq("(1 (2 3))")
    end

    it "let-values (non-sequential) and let*-values (sequential)" do
      w("(let-values (((a b) (values 1 2)) ((c) (values 3))) (list a b c))").should eq("(1 2 3)")
      w("(let*-values (((a b) (values 1 2)) ((c) (values (+ a b)))) (list a b c))").should eq("(1 2 3)")
    end

    it "call-with-values bridges through Interpreter#apply correctly" do
      w("(call-with-values (lambda () (values 1 2)) (lambda (a b) (+ a b)))").should eq("3")
    end
  end

  describe "parameterize" do
    it "restores the saved value after the body, including nested and converter cases" do
      w("(define p (make-parameter 10)) (list (p) (parameterize ((p 20)) (p)) (p))")
        .should eq("(10 20 10)")
      w("(define p (make-parameter 5 (lambda (v) (* v 2))))" \
        "(list (p) (parameterize ((p 3)) (p)) (p))").should eq("(10 6 10)")
      w("(define p (make-parameter 1)) (define (f) (p))" \
        "(parameterize ((p 99)) (list (f) (parameterize ((p 100)) (f)) (f)))").should eq("(99 100 99)")
    end
  end

  describe "guard" do
    it "catches an error and runs the matching clause" do
      w("(guard (e (#t (list 'caught (error-object? e) (error-object-message e))))" \
        "  (error \"boom\" 1 2))").should eq("(caught #t \"boom\")")
      w("(guard (e ((symbol? e) (list 'sym e)) (#t (list 'other e))) (raise 'oops))")
        .should eq("(sym oops)")
    end

    it "catches an error raised from a non-tail call deep inside the body" do
      w("(define (f n) (guard (e (#t (list 'caught n)))" \
        "  (if (= n 0) (error \"boom\") 'ok)))" \
        "(list (f 1) (f 0))").should eq("(ok (caught 0))")
    end

    it "re-raises to an outer guard when no clause matches" do
      w("(guard (e1 (#t (list 'outer e1)))" \
        "  (guard (e2 ((string? e2) (list 'inner-string e2))) (raise 'not-a-string)))")
        .should eq("(outer not-a-string)")
    end

    it "unwinds cleanly through several levels of non-tail recursion" do
      w("(define log '())" \
        "(define (rec n)" \
        "  (guard (e (#t (set! log (cons 'caught log)) 'handled))" \
        "    (if (= n 0) (error \"deep\")" \
        "        (begin (set! log (cons n log)) (rec (- n 1))))))" \
        "(rec 5) (reverse log)").should eq("(5 4 3 2 1 caught)")
    end

    it "can appear as an ordinary operand mid-expression" do
      w("(+ 1 (guard (e (#t 100)) (car 5)))").should eq("101")
    end
  end

  describe "dynamic-wind, call/cc, with-exception-handler (already plain Builtins — no VM-specific code needed)" do
    it "runs before/thunk/after in order" do
      w("(define log '())" \
        "(dynamic-wind" \
        "  (lambda () (set! log (cons 'before log)))" \
        "  (lambda () (set! log (cons 'during log)))" \
        "  (lambda () (set! log (cons 'after log))))" \
        "(reverse log)").should eq("(before during after)")
    end

    it "still runs after when thunk errors, caught by an outer guard" do
      w("(define log '())" \
        "(guard (e (#t 'caught))" \
        "  (dynamic-wind" \
        "    (lambda () (set! log (cons 'before log)))" \
        "    (lambda () (error \"fail\"))" \
        "    (lambda () (set! log (cons 'after log)))))" \
        "(reverse log)").should eq("(before after)")
    end

    it "call/cc escapes immediately, discarding the rest of its own call site" do
      w("(+ 1 (call/cc (lambda (k) (+ 2 (k 10)))))").should eq("11")
    end

    it "call/cc escapes a for-each loop early" do
      w("(call/cc (lambda (return)" \
        "  (for-each (lambda (x) (if (= x 3) (return x))) '(1 2 3 4 5))" \
        "  'not-found))").should eq("3")
    end

    it "escaping a dynamic-wind's thunk via a captured continuation still runs after" do
      w("(define log '())" \
        "(call/cc (lambda (k)" \
        "  (dynamic-wind" \
        "    (lambda () (set! log (cons 'in log)))" \
        "    (lambda () (k 'escaped))" \
        "    (lambda () (set! log (cons 'out log))))))" \
        "(reverse log)").should eq("(in out)")
    end

    it "raise-continuable calls the handler in-line and uses its return value" do
      w("(with-exception-handler" \
        "  (lambda (e) 1000)" \
        "  (lambda () (+ 1 (raise-continuable 'oops))))").should eq("1001")
    end
  end

  describe "quasiquote" do
    it "evaluates unquote, unquote-splicing, vectors, and nested quasiquote" do
      w("(define x 5) `(a b ,x ,(+ x 1))").should eq("(a b 5 6)")
      w("(define lst '(2 3 4)) `(1 ,@lst 5)").should eq("(1 2 3 4 5)")
      w("`#(1 ,(+ 1 1) 3)").should eq("#(1 2 3)")
      w("``(a ,(b ,(+ 1 2)))").should eq("(quasiquote (a (unquote (b 3))))")
    end
  end

  describe "delay/force" do
    it "memoizes — the thunk runs only once across repeated force calls" do
      w("(import (scheme lazy))" \
        "(define count 0)" \
        "(define p (delay (begin (set! count (+ count 1)) count)))" \
        "(list (force p) (force p) count)").should eq("(1 1 1)")
    end
  end

  describe "define-record-type" do
    it "builds a constructor, predicate, accessors, and mutator" do
      w("(define-record-type point" \
        "  (make-point x y)" \
        "  point?" \
        "  (x point-x set-point-x!)" \
        "  (y point-y set-point-y!))" \
        "(define p (make-point 3 4))" \
        "(set-point-x! p 10)" \
        "(list (point? p) (point-x p) (point-y p) (point? 5))").should eq("(#t 10 4 #f)")
    end
  end

  describe "define-syntax / defmacro" do
    it "expands syntax-rules macros, including ones affecting LATER top-level forms" do
      w("(define-syntax my-if (syntax-rules () ((_ c t e) (cond (c t) (else e)))))" \
        "(my-if #t 'yes 'no)").should eq("yes")
      w("(define-syntax swap! (syntax-rules () ((_ a b) (let ((tmp a)) (set! a b) (set! b tmp)))))" \
        "(define x 1) (define y 2) (swap! x y) (list x y)").should eq("(2 1)")
    end
  end

  describe "do" do
    it "builds a vector via mutation across iterations" do
      w("(do ((vec (make-vector 5)) (i 0 (+ i 1))) ((= i 5) vec) (vector-set! vec i i))")
        .should eq("#(0 1 2 3 4)")
    end

    it "supports a self-tail-recursive accumulation with no explicit step for some vars" do
      w("(do ((x 1 (* x 2)) (i 0 (+ i 1))) ((= i 20) x))").should eq("1048576")
    end

    it "returns unspecified with no result forms" do
      w("(do ((i 0 (+ i 1))) ((= i 3)))").should eq("()")
    end
  end
end
