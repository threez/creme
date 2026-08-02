require "../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, src).write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, src)
end

# The analyzer specializes a handful of fixed-arity builtins (arithmetic
# comparisons, vector-ref/vector-set!/vector-length, string-ref/string-set!,
# bytevector-u8-ref/bytevector-u8-set!) into an inlined PrimCallNode when the
# call site's head is a free, non-shadowed global still bound to the expected
# builtin (see ast.cr's PrimOp/PRIM_OPS and eval_node.cr's PrimCallNode arm).
# If that name is redefined, the specialized call site must deopt to the new
# binding rather than silently keep running the original builtin.
describe "primitive call specialization" do
  it "deopts + to a runtime redefinition" do
    w("(define (+ a b) (list 'shadowed a b)) (+ 1 2)").should eq("(shadowed 1 2)")
  end

  it "deopts vector-ref to a runtime redefinition" do
    w("(define (vector-ref v i) 'shadowed) (vector-ref (vector 1 2) 0)").should eq("shadowed")
  end

  it "deopts vector-set! to a runtime redefinition" do
    w("(define (vector-set! v i x) 'shadowed) (vector-set! (vector 1 2) 0 9)").should eq("shadowed")
  end

  it "deopts vector-length to a runtime redefinition" do
    w("(define (vector-length v) 'shadowed) (vector-length (vector 1 2))").should eq("shadowed")
  end

  it "deopts string-ref to a runtime redefinition" do
    w("(define (string-ref s i) 'shadowed) (string-ref \"ab\" 0)").should eq("shadowed")
  end

  it "deopts string-set! to a runtime redefinition" do
    w("(define (string-set! s i c) 'shadowed) (string-set! (make-string 2) 0 #\\a)").should eq("shadowed")
  end

  it "deopts bytevector-u8-ref to a runtime redefinition" do
    w("(define (bytevector-u8-ref b i) 'shadowed) (bytevector-u8-ref (make-bytevector 2) 0)").should eq("shadowed")
  end

  it "deopts bytevector-u8-set! to a runtime redefinition" do
    w("(define (bytevector-u8-set! b i x) 'shadowed) (bytevector-u8-set! (make-bytevector 2) 0 1)").should eq("shadowed")
  end

  it "does not specialize a call whose head is shadowed by a local binding" do
    w("(define v (vector 1 2)) (let ((vector-ref (lambda (v i) 'local))) (vector-ref v 0))").should eq("local")
  end

  it "still works normally (no redefinition) for every specialized op" do
    w("(vector-ref (vector 1 2 3) 1)").should eq("2")
    w("(let ((v (vector 1 2 3))) (vector-set! v 1 99) v)").should eq("#(1 99 3)")
    w("(vector-length (vector 1 2 3))").should eq("3")
    w("(string-ref \"abc\" 1)").should eq("#\\b")
    w("(let ((s (make-string 3 #\\a))) (string-set! s 1 #\\z) s)").should eq("\"aza\"")
    w("(bytevector-u8-ref (bytevector 1 2 3) 1)").should eq("2")
    w("(let ((b (make-bytevector 3 0))) (bytevector-u8-set! b 1 42) b)").should eq("#u8(0 42 0)")
  end

  # Every specialized op additionally fetches a Literal/VarRef/LocalRef/
  # GlobalRef operand directly inline rather than via a separate eval_node
  # call (see eval_node.cr's prim_operand_value) — covers that fast path
  # still produces correct results and correct error positions/behavior,
  # for every op that uses it.
  describe "inlined operand fast path" do
    it "computes correctly with local/global/literal operands mixed (arithmetic/comparison)" do
      w("(define (f n) (+ (- n 1) (* n 2))) (f 5)").should eq("14")
      w("(< 1 2)").should eq("#t")
      w("(<= 2 2)").should eq("#t")
      w("(> 3 2)").should eq("#t")
      w("(>= 2 2)").should eq("#t")
      w("(= 2 2)").should eq("#t")
    end

    it "computes correctly with local/global/literal operands (vector/string/bytevector)" do
      w("(define (f v i) (vector-ref v i)) (f (vector 10 20 30) 1)").should eq("20")
      w("(define (f v i x) (vector-set! v i x) v) (f (vector 1 2) 0 9)").should eq("#(9 2)")
      w("(define (f v) (vector-length v)) (f (vector 1 2 3))").should eq("3")
      w("(define (f s i) (string-ref s i)) (f \"abc\" 1)").should eq("#\\b")
      w("(define (f s i c) (string-set! s i c) s) (f (make-string 2 #\\z) 0 #\\a)").should eq("\"az\"")
      w("(define (f b i) (bytevector-u8-ref b i)) (f (bytevector 1 2 3) 1)").should eq("2")
      w("(define (f b i x) (bytevector-u8-set! b i x) b) (f (make-bytevector 2) 0 42)").should eq("#u8(42 0)")
    end

    it "still evaluates a non-leaf operand (not eligible for the inline fetch) correctly" do
      w("(define (double x) (* x 2)) (+ (double 3) 1)").should eq("7")
      w("(define (idx) 1) (vector-ref (vector 10 20 30) (idx))").should eq("20")
    end

    it "reports an unbound-variable error at the operand's own position, not the call's" do
      expect_raises(Scheme::SchemeRuntimeError, /unbound variable: y/) do
        run("(define x 1)\n(+ x y)")
      end
    end
  end

  # compile_prim_call reads a bare local-variable operand directly out of
  # its own register (no staging Move) when every argument in the call is a
  # side-effect-free leaf (Literal/VarRef/LocalRef/GlobalRef) — see
  # local_register_of?/leaf_node? in bytecode_compiler.cr. The gate is on the
  # WHOLE call, not per-argument, specifically to avoid an aliasing hazard:
  # eliding an earlier argument's Move while a later sibling argument can
  # still mutate that same local before the op runs would let the op observe
  # a post-mutation value where a pre-mutation snapshot was required.
  describe "local-operand register reuse (no staging Move)" do
    it "still snapshots an earlier local operand before a later sibling's side effect mutates it" do
      w("(let ((n 5)) (+ n (begin (set! n 10) n)))").should eq("15")
    end

    it "computes correctly when every operand is an eligible local/global/literal leaf" do
      w("(let ((n 5)) (- n 1))").should eq("4")
      w("(let ((a 1) (b 2)) (+ a b))").should eq("3")
      w("(let ((n 3)) (< n 2))").should eq("#f")
    end

    it "still computes correctly when the same local is read twice in one call" do
      w("(let ((n 5)) (+ n n))").should eq("10")
    end
  end

  # A 2-arg arithmetic/comparison call whose 2nd argument is a small integer
  # literal (fitting Instruction's Int32 operand fields) compiles to an
  # AddImm-family op instead of staging the literal through its own register
  # + LoadK first — see imm_operand?/imm_op_for in bytecode_compiler.cr.
  # Only the 2nd argument position is supported (order matters for the
  # non-commutative ops here).
  describe "small-integer immediate operand (Imm ops)" do
    it "computes correctly for every Imm-eligible op, with a local 1st operand" do
      w("(let ((n 5)) (+ n 1))").should eq("6")
      w("(let ((n 5)) (- n 1))").should eq("4")
      w("(let ((n 5)) (* n 2))").should eq("10")
      w("(let ((n 5)) (< n 2))").should eq("#f")
      w("(let ((n 5)) (<= n 5))").should eq("#t")
      w("(let ((n 5)) (> n 2))").should eq("#t")
      w("(let ((n 5)) (>= n 5))").should eq("#t")
      w("(let ((n 5)) (= n 5))").should eq("#t")
    end

    it "computes correctly with a global 1st operand" do
      w("(define n 5) (+ n 1)").should eq("6")
      w("(define n 5) (- n 1)").should eq("4")
      w("(define n 5) (* n 2)").should eq("10")
      w("(define n 5) (< n 2)").should eq("#f")
      w("(define n 5) (= n 5)").should eq("#t")
    end

    it "falls back to the general path for a literal too large for Int32" do
      w("(let ((n 10)) (- n 5000000000))").should eq("-4999999990")
      w("(let ((n 10)) (+ n 5000000000))").should eq("5000000010")
    end

    it "falls back to the numeric tower for a non-integer 1st operand" do
      w("(< 1.5 2)").should eq("#t")
      w("(let ((x 1.5)) (< x 2))").should eq("#t")
      w("(let ((x (/ 3 2))) (< x 2))").should eq("#t")
      w("(let ((x 1.5)) (+ x 1))").should eq("2.5")
    end

    it "still deopts to a runtime redefinition (Imm-shaped call site)" do
      w("(define (+ a b) (list 'shadowed a b)) (+ 1 2)").should eq("(shadowed 1 2)")
    end

    it "still respects ordinary set!-then-read sequencing" do
      w("(let ((n 5)) (begin (set! n 7) (- n 1)))").should eq("6")
    end
  end

  # A 2-arg arithmetic/comparison call whose 2nd argument is a bare
  # closed-over variable (an upvalue — e.g. a named-let loop reading a
  # variable bound by its enclosing function) compiles to an AddUp-family
  # op instead of staging it through its own register + GetUpval first —
  # see up_operand?/up_op_for_2nd in bytecode_compiler.cr. Only the 2nd
  # argument position is supported, mirroring the Imm family.
  describe "closed-over 2nd operand (arithmetic/comparison Up ops)" do
    it "computes correctly for every Up-eligible op, with the captured variable as the 2nd operand" do
      w("(let ((n 5)) (let ((f (lambda (x) (+ x n)))) (f 1)))").should eq("6")
      w("(let ((n 5)) (let ((f (lambda (x) (- x n)))) (f 1)))").should eq("-4")
      w("(let ((n 5)) (let ((f (lambda (x) (* x n)))) (f 2)))").should eq("10")
      w("(let ((n 5)) (let ((f (lambda (x) (< x n)))) (f 2)))").should eq("#t")
      w("(let ((n 5)) (let ((f (lambda (x) (<= x n)))) (f 5)))").should eq("#t")
      w("(let ((n 5)) (let ((f (lambda (x) (> x n)))) (f 6)))").should eq("#t")
      w("(let ((n 5)) (let ((f (lambda (x) (>= x n)))) (f 5)))").should eq("#t")
      w("(let ((n 5)) (let ((f (lambda (x) (= x n)))) (f 5)))").should eq("#t")
    end

    it "still exercises the loop shape this was profiled from" do
      w(<<-SCM).should eq("20")
        (define (vector-sum-test n)
          (let ((v (make-vector n 0)))
            (let loop ((i 0))
              (if (< i n)
                  (begin (vector-set! v i (* i 2)) (loop (+ i 1)))))
            (let loop ((i 0) (acc 0))
              (if (= i n) acc (loop (+ i 1) (+ acc (vector-ref v i)))))))
        (vector-sum-test 5)
      SCM
    end

    it "falls back to the numeric tower for a non-integer captured operand" do
      w("(let ((n 1.5)) (let ((f (lambda (x) (+ x n)))) (f 1)))").should eq("2.5")
    end

    it "does not fuse (and stays correct) when the 1st operand isn't a leaf" do
      w("(let ((n 5)) (let ((f (lambda () (< (begin (set! n 100) 0) n)))) (f)))").should eq("#t")
    end

    it "still deopts to a runtime redefinition" do
      w("(define (+ a b) (list 'shadowed a b)) (let ((n 2)) (let ((f (lambda (x) (+ x n)))) (f 1)))").should eq("(shadowed 1 2)")
    end
  end

  # A vector/string/bytevector call whose 1st argument (the object) is a
  # bare closed-over variable compiles to a *Up op instead of staging it
  # through its own register + GetUpval first — see up_operand?/
  # up_op_for_1st in bytecode_compiler.cr. Gated on every OTHER argument
  # being a leaf, since (unlike the arithmetic case) the object is read
  # LAST in the fused instruction despite being written FIRST in the
  # source — an unsafe reorder if a later argument could mutate it first.
  describe "closed-over object operand (vector/string/bytevector Up ops)" do
    it "computes correctly for vector-ref/vector-set!/vector-length" do
      w("(let ((v (vector 1 2 3))) (let ((f (lambda (i) (vector-ref v i)))) (f 1)))").should eq("2")
      w("(let ((v (vector 1 2 3))) (let ((f (lambda (i x) (vector-set! v i x) v))) (f 1 9)))").should eq("#(1 9 3)")
      w("(let ((v (vector 1 2 3))) (let ((f (lambda () (vector-length v)))) (f)))").should eq("3")
    end

    it "computes correctly for string-ref/string-set!" do
      w("(let ((s \"abc\")) (let ((f (lambda (i) (string-ref s i)))) (f 1)))").should eq("#\\b")
      w("(let ((s (make-string 2 #\\z))) (let ((f (lambda (i c) (string-set! s i c) s))) (f 0 #\\a)))").should eq("\"az\"")
    end

    it "computes correctly for bytevector-u8-ref/bytevector-u8-set!" do
      w("(let ((b (bytevector 1 2 3))) (let ((f (lambda (i) (bytevector-u8-ref b i)))) (f 1)))").should eq("2")
      w("(let ((b (make-bytevector 2 0))) (let ((f (lambda (i x) (bytevector-u8-set! b i x) b))) (f 0 42)))").should eq("#u8(42 0)")
    end

    it "does not fuse (and stays correct) when a later argument mutates the captured object first" do
      w(<<-SCM).should eq("#(99 99 99)")
        (let ((v (vector 10 20 30)))
          (let ((f (lambda (x)
                     (vector-set! v (begin (set! v (vector 99 99 99)) 0) x)
                     v)))
            (f 5)))
      SCM
    end

    it "still deopts to a runtime redefinition" do
      w("(define (vector-ref v i) 'shadowed) (let ((vv (vector 1 2))) (let ((f (lambda (i) (vector-ref vv i)))) (f 0)))").should eq("shadowed")
    end
  end

  # A vector-ref/vector-set!/string-ref/string-set!/bytevector-u8-ref/
  # bytevector-u8-set! call whose INDEX argument is a small integer
  # literal (fitting Instruction's Int32 operand fields) compiles to a
  # *RefImm/*SetImm op instead of staging it through its own register +
  # LoadK first — see the dedicated index-immediate branch in
  # bytecode_compiler.cr's compile_prim_call (reuses imm_operand? from the
  # arithmetic Imm family, but applies to the INDEX argument rather than
  # the whole 2nd operand, and covers the *Set ops' 3-arg shape too, not
  # just 2-arg calls) and imm_index_ref_op_for/imm_index_set_op_for
  # (mirroring up_op_for_1st's uniform vector/string/bytevector treatment).
  describe "vector/string/bytevector index immediate operand (*RefImm/*SetImm ops)" do
    it "computes correctly for vector-ref/vector-set! with a literal index" do
      w("(vector-ref (vector 10 20 30) 1)").should eq("20")
      w("(let ((v (vector 1 2 3))) (vector-set! v 1 99) v)").should eq("#(1 99 3)")
    end

    it "computes correctly with a local vector operand" do
      w("(let ((v (vector 10 20 30))) (vector-ref v 2))").should eq("30")
      w("(let ((v (vector 1 2 3))) (vector-set! v 0 9) v)").should eq("#(9 2 3)")
    end

    it "computes correctly with a global vector operand" do
      w("(define v (vector 10 20 30)) (vector-ref v 0)").should eq("10")
    end

    it "still evaluates a non-literal index correctly (general path, not fused)" do
      w("(vector-ref (vector 1 2 3) (+ 1 0))").should eq("2")
    end

    it "still snapshots the object before a later argument's side effect mutates it (vector-set!)" do
      w(<<-SCM).should eq("#(99 99 99)")
        (let ((v (vector 10 20 30)))
          (vector-set! v 0 (begin (set! v (vector 99 99 99)) 5))
          v)
        SCM
    end

    it "raises on an out-of-range literal index" do
      expect_raises(Scheme::SchemeRuntimeError, /index 5 out of range/) do
        run("(vector-ref (vector 1 2 3) 5)")
      end
    end

    it "still deopts to a runtime redefinition (VecRefImm/VecSetImm-shaped call site)" do
      w("(define (vector-ref v i) 'shadowed) (vector-ref (vector 1 2) 0)").should eq("shadowed")
      w("(define (vector-set! v i x) 'shadowed) (vector-set! (vector 1 2) 0 9)").should eq("shadowed")
    end

    it "computes correctly for string-ref/string-set! with a literal index" do
      w("(string-ref \"abc\" 1)").should eq("#\\b")
      w("(let ((s (make-string 3 #\\a))) (string-set! s 1 #\\z) s)").should eq("\"aza\"")
    end

    it "still snapshots the string before a later argument's side effect mutates it (string-set!)" do
      w(<<-SCM).should eq("\"zzz\"")
        (let ((s (make-string 3 #\\a)))
          (string-set! s 0 (begin (set! s (make-string 3 #\\z)) #\\q))
          s)
        SCM
    end

    it "raises on an out-of-range literal index (string-ref)" do
      expect_raises(Scheme::SchemeRuntimeError, /index out of range/) do
        run("(string-ref \"abc\" 5)")
      end
    end

    it "still deopts to a runtime redefinition (string Imm-shaped call site)" do
      w("(define (string-ref s i) 'shadowed) (string-ref \"ab\" 0)").should eq("shadowed")
      w("(define (string-set! s i c) 'shadowed) (string-set! (make-string 2) 0 #\\a)").should eq("shadowed")
    end

    it "computes correctly for bytevector-u8-ref/bytevector-u8-set! with a literal index" do
      w("(bytevector-u8-ref (bytevector 1 2 3) 1)").should eq("2")
      w("(let ((b (make-bytevector 3 0))) (bytevector-u8-set! b 1 42) b)").should eq("#u8(0 42 0)")
    end

    it "still snapshots the bytevector before a later argument's side effect mutates it (bytevector-u8-set!)" do
      w(<<-SCM).should eq("#u8(9 9 9)")
        (let ((b (make-bytevector 3 0)))
          (bytevector-u8-set! b 0 (begin (set! b (make-bytevector 3 9)) 1))
          b)
        SCM
    end

    it "raises on an out-of-range literal index (bytevector-u8-ref)" do
      expect_raises(Scheme::SchemeRuntimeError, /index out of range/) do
        run("(bytevector-u8-ref (bytevector 1 2 3) 5)")
      end
    end

    it "still deopts to a runtime redefinition (bytevector Imm-shaped call site)" do
      w("(define (bytevector-u8-ref b i) 'shadowed) (bytevector-u8-ref (make-bytevector 2) 0)").should eq("shadowed")
      w("(define (bytevector-u8-set! b i x) 'shadowed) (bytevector-u8-set! (make-bytevector 2) 0 1)").should eq("shadowed")
    end
  end

  # (if/when test ...) compiles a fused TestLt-family instruction instead
  # of a comparison op followed by a separate TestFalse, when the test
  # expression IS exactly a bare 2-arg comparison call — see
  # compile_fused_test/comparison_op_of in bytecode_compiler.cr. Safe
  # specifically for if/when (whose test value is only ever used for
  # truthiness); cond/guard clause tests are NOT fused, since a bodyless
  # clause or a `=>` arrow can use the test's own value, not just whether
  # it's truthy.
  describe "compare-and-branch fusion (if/when Test* ops)" do
    it "computes correctly for every comparison, plain register operands" do
      w("(let ((a 1) (b 2)) (if (< a b) 'yes 'no))").should eq("yes")
      w("(let ((a 2) (b 2)) (if (<= a b) 'yes 'no))").should eq("yes")
      w("(let ((a 3) (b 2)) (if (> a b) 'yes 'no))").should eq("yes")
      w("(let ((a 2) (b 2)) (if (>= a b) 'yes 'no))").should eq("yes")
      w("(let ((a 2) (b 2)) (if (= a b) 'yes 'no))").should eq("yes")
      w("(let ((a 5) (b 2)) (if (< a b) 'yes 'no))").should eq("no")
    end

    it "computes correctly with a small-integer-literal 2nd operand (Imm)" do
      w("(let ((n 1)) (if (< n 2) 'yes 'no))").should eq("yes")
      w("(let ((n 5)) (if (< n 2) 'yes 'no))").should eq("no")
      w("(let ((n 5)) (if (<= n 5) 'yes 'no))").should eq("yes")
      w("(let ((n 5)) (if (> n 5) 'yes 'no))").should eq("no")
      w("(let ((n 5)) (if (>= n 5) 'yes 'no))").should eq("yes")
      w("(let ((n 5)) (if (= n 5) 'yes 'no))").should eq("yes")
    end

    it "computes correctly with a closed-over 2nd operand (Up)" do
      w("(let ((n 5)) (let ((f (lambda (x) (if (< x n) 'yes 'no)))) (f 2)))").should eq("yes")
      w("(let ((n 5)) (let ((f (lambda (x) (if (< x n) 'yes 'no)))) (f 9)))").should eq("no")
      w(<<-SCM).should eq("20")
        (define (vector-sum-test n)
          (let ((v (make-vector n 0)))
            (let loop ((i 0))
              (if (< i n)
                  (begin (vector-set! v i (* i 2)) (loop (+ i 1)))))
            (let loop ((i 0) (acc 0))
              (if (= i n) acc (loop (+ i 1) (+ acc (vector-ref v i)))))))
        (vector-sum-test 5)
      SCM
    end

    it "works the same for when/unless (negated test)" do
      w("(when (< 1 2) 'yes)").should eq("yes")
      w("(unless (< 1 2) 'yes)").should eq("()")
      w("(unless (> 1 2) 'yes)").should eq("yes")
    end

    it "falls back to the general path for a literal too large for Int32" do
      w("(let ((n 10)) (if (< n 100000000000) 'yes 'no))").should eq("yes")
    end

    it "falls back to the numeric tower for a non-integer operand" do
      w("(if (< 1.5 2) 'yes 'no)").should eq("yes")
      w("(let ((x 1.5)) (if (< x 2) 'yes 'no))").should eq("yes")
    end

    it "does not fuse (and stays correct) when the 1st operand isn't a leaf" do
      w("(let ((n 5)) (let ((f (lambda () (if (< (begin (set! n 100) 0) n) 'yes 'no)))) (f)))").should eq("yes")
    end

    it "leaves cond/guard clause tests unfused, since their value can be observed" do
      w("(cond ((< 1 2)) (else 'none))").should eq("#t")
      w("(cond ((assoc 2 (list (cons 1 'a) (cons 2 'b))) => cdr) (else 'none))").should eq("b")
    end

    it "still deopts to a runtime redefinition" do
      w("(define (< a b) 'shadowed) (if (< 1 2) 'yes 'no)").should eq("yes")
    end

    it "still compiles a non-comparison test through the general path" do
      w("(if 'ok 1 2)").should eq("1")
      w("(if (car (list #t)) 1 2)").should eq("1")
    end
  end

  # A call whose callee is a bare variable reference fuses the callee load
  # (GetGlobal/Move/GetUpval) directly into the call — CallGlobal for a
  # global callee, CallLocal for a local, CallUpval for a closed-over one
  # (each with a tail variant) — instead of staging the callee through its
  # own register first. See bare_callee_source/compile_app in
  # bytecode_compiler.cr. A compound callee (a nested call, an inline
  # lambda) still compiles through the general path.
  describe "fused callee load (Call* ops)" do
    it "computes correctly for a global callee (non-tail and tail)" do
      w("(define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (fib 10)").should eq("55")
      w("(define (sum-to n acc) (if (= n 0) acc (sum-to (- n 1) (+ acc n)))) (sum-to 1000 0)").should eq("500500")
    end

    it "computes correctly for a local callee" do
      w("(let ((sq (lambda (x) (* x x)))) (sq 7))").should eq("49")
      w("(let ((add (lambda (a b) (+ a b)))) (add 3 4))").should eq("7")
    end

    it "computes correctly for a closed-over (upvalue) callee, incl. named-let loops" do
      w("(define (build n) (let loop ((i 0) (acc '())) (if (= i n) acc (loop (+ i 1) (cons i acc))))) (length (build 100))").should eq("100")
      w("(let ((f (lambda (x) (* x 2)))) (let ((g (lambda (y) (f (f y))))) (g 5)))").should eq("20")
    end

    it "computes correctly for mutual recursion (both global)" do
      w("(define (ev? n) (if (= n 0) #t (od? (- n 1)))) (define (od? n) (if (= n 0) #f (ev? (- n 1)))) (list (ev? 10) (ev? 7))").should eq("(#t #f)")
    end

    it "picks up a runtime redefinition of a global callee (cache version check)" do
      w("(define (f) (g)) (define (g) 1) (define a (f)) (set! g (lambda () 2)) (define b (f)) (list a b)").should eq("(1 2)")
    end

    it "calls the global, not a same-named local shadowing it elsewhere" do
      w("(define (h x) (* x 10)) (list (let ((h (lambda (x) (+ x 100)))) (h 5)) (h 5))").should eq("(105 50)")
    end

    it "still compiles a compound callee through the general path" do
      w("(define fns (list (lambda (x) (+ x 1)) (lambda (x) (* x 2)))) (list ((car fns) 5) ((cadr fns) 5))").should eq("(6 10)")
      w("((lambda (x y) (+ x y)) 3 4)").should eq("7")
    end
  end

  # A bare variable reference in tail position skips materializing its
  # value into dst before returning it: a local Returns straight from its
  # own register (no Move); a global/upvalue resolves via ReturnGlobal/
  # ReturnUpval, delivering directly without ever writing a register. See
  # compile_name_read's `tail` parameter in bytecode_compiler.cr.
  describe "fused tail return (bare name in tail position)" do
    it "returns a local directly, including when dst differs from its own register" do
      w("(define (second a b) b) (second 1 2)").should eq("2")
      w("(define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (fib 10)").should eq("55")
    end

    it "returns a global directly (ReturnGlobal)" do
      w("(define x 5) (define (f) x) (f)").should eq("5")
    end

    it "returns a closed-over upvalue directly (ReturnUpval)" do
      w("(let ((v 42)) (let ((g (lambda () v))) (g)))").should eq("42")
    end

    it "still works correctly for a non-tail read of the same shapes" do
      w("(define x 5) (define (f) x) (+ 1 (f))").should eq("6")
      w("(+ 1 (let ((v 1)) (let ((h (lambda () v))) (h))))").should eq("2")
    end

    it "picks up a runtime redefinition of a returned global" do
      w("(define (f) g) (define g 1) (define a (f)) (set! g 2) (define b (f)) (list a b)").should eq("(1 2)")
    end
  end

  # A base 2-arg arithmetic/comparison prim call in tail position fuses
  # straight into its own Return-flavored op (AddReturn/SubReturn/.../
  # NumEqReturn) instead of emitting the op followed by a separate Return
  # — closes fib's own recursive-case `return` bucket. See
  # return_op_for/compile_prim_call's `tail` parameter.
  describe "fused tail return (prim call in tail position)" do
    it "fuses fib's own tail (+ (fib ...) (fib ...)) shape (AddReturn)" do
      w("(define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (fib 10)").should eq("55")
    end

    it "fuses a plain 2-register-operand tail op" do
      w("(define (f a b) (+ a b)) (f 3 4)").should eq("7")
      w("(define (f a b) (< a b)) (f 3 4)").should eq("#t")
    end

    it "does not fuse a non-tail prim call" do
      w("(define (f a b) (+ (+ a b) 1)) (f 3 4)").should eq("8")
    end

    it "does not affect vector-set!/string-set!/bytevector-u8-set! in tail position (unfused, still return the object)" do
      w("(define (f v i x) (vector-set! v i x) v) (define v (vector 1 2 3)) (f v 0 9) (vector->list v)").should eq("(9 2 3)")
      w("(define (f v i x) (vector-set! v i x)) (define v (vector 1 2 3)) (f v 0 9) (vector->list v)").should eq("(9 2 3)")
    end

    it "still deopts a tail-position call when + is redefined before compiling" do
      w("(define (+ a b) (list 'shadowed a b)) (define (f a b) (+ a b)) (f 1 2)").should eq("(shadowed 1 2)")
    end
  end

  # eq? gets the same full op family as the numeric comparisons (base
  # Op::IsEq, IsEqImm, IsEqUp, TestIsEq/TestIsEqImm/TestIsEqUp, IsEqReturn)
  # instead of compiling to a generic dynamic call — see ast.cr's
  # PrimOp::IsEq doc comment. Unlike NumEq, it never raises and never needs
  # a numeric-tower fallback (it's literally Scheme.scheme_eqv? — eq? and
  # eqv? share one implementation, see arithmetic.cr's eq_p/eqv_p), so
  # these specs lean on that simplicity rather than mirroring every
  # NumEq-family edge case (there's no "falls back to the numeric tower"
  # shape for eq? to test).
  describe "eq? fusion (IsEq family)" do
    it "computes correctly for the base 2-register op, across value types" do
      w("(let ((a 'x) (b 'x)) (eq? a b))").should eq("#t")
      w("(let ((a 'x) (b 'y)) (eq? a b))").should eq("#f")
      w("(let ((a 5) (b 5)) (eq? a b))").should eq("#t")
      w("(let ((a 5) (b 5.0)) (eq? a b))").should eq("#f")
      w("(let ((a #\\a) (b #\\a)) (eq? a b))").should eq("#t")
      w("(let ((a #t) (b #t)) (eq? a b))").should eq("#t")
      w("(let ((a '()) (b '())) (eq? a b))").should eq("#t")
      w("(let ((p (cons 1 2))) (eq? p p))").should eq("#t")
      w("(eq? (cons 1 2) (cons 1 2))").should eq("#f")
      w("(eq? 0.0 -0.0)").should eq("#f")
    end

    it "computes correctly with a small-integer-literal 2nd operand (Imm)" do
      w("(let ((n 5)) (eq? n 5))").should eq("#t")
      w("(let ((n 5)) (eq? n 6))").should eq("#f")
      w("(let ((n 'sym)) (eq? n 5))").should eq("#f")
    end

    it "falls back to the general path for a literal too large for Int32" do
      w("(let ((n 5)) (eq? n 5000000000))").should eq("#f")
    end

    it "computes correctly with a closed-over 2nd operand (Up)" do
      w("(let ((n 5)) (let ((f (lambda (x) (eq? x n)))) (f 5)))").should eq("#t")
      w("(let ((n 5)) (let ((f (lambda (x) (eq? x n)))) (f 6)))").should eq("#f")
      w("(let ((n 'sym)) (let ((f (lambda (x) (eq? x n)))) (f 'sym)))").should eq("#t")
    end

    it "computes correctly for the if/when fused compare-and-branch (TestIsEq family)" do
      w("(if (eq? 'x 'x) 'yes 'no)").should eq("yes")
      w("(if (eq? 'x 'y) 'yes 'no)").should eq("no")
      w("(let ((n 5)) (if (eq? n 5) 'yes 'no))").should eq("yes")
      w("(let ((n 5)) (let ((f (lambda (x) (if (eq? x n) 'yes 'no)))) (f 5)))").should eq("yes")
      w("(when (eq? 1 1) 'yes)").should eq("yes")
      w("(unless (eq? 1 1) 'yes)").should eq("()")
    end

    it "leaves cond/guard clause tests unfused (materializes via base IsEq + TestFalse), since their value can be observed" do
      w("(cond ((eq? 1 1)) (else 'none))").should eq("#t")
      w(<<-SCM).should eq("b")
        (define (get-list alist key)
          (cond ((null? alist) #f)
                ((eq? (caar alist) key) (cdar alist))
                (else (get-list (cdr alist) key))))
        (get-list (list (cons 'a 'a-val) (cons 'b 'b)) 'b)
      SCM
    end

    it "fuses a plain 2-register-operand tail call (IsEqReturn)" do
      w("(define (f a b) (eq? a b)) (f 3 3)").should eq("#t")
      w("(define (f a b) (eq? a b)) (f 3 4)").should eq("#f")
    end

    it "still deopts to a runtime redefinition" do
      w("(define (eq? a b) 'shadowed) (eq? 1 1)").should eq("shadowed")
      w("(define (eq? a b) 'shadowed) (if (eq? 1 1) 'yes 'no)").should eq("yes")
      w("(define (eq? a b) 'shadowed) (define (f a b) (eq? a b)) (f 1 1)").should eq("shadowed")
    end

    it "does not specialize a call whose head is shadowed by a local binding" do
      w("(let ((eq? (lambda (a b) 'local))) (eq? 1 1))").should eq("local")
    end
  end
end
