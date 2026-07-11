require "../spec_helper"

private def run(src : String) : LISP::LispValue
  interp = LISP::Interpreter.new
  LISP.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe LISP::Interpreter do
  describe "quote" do
    it "returns the form unevaluated" do
      w("(quote (a b c))").should eq("(a b c)")
    end

    it "raises for the wrong number of arguments" do
      expect_raises(LISP::LispRuntimeError, /quote: expects 1 argument/) do
        run("(quote a b)")
      end
    end
  end

  describe "quasiquote/unquote/unquote-splicing" do
    it "evaluates unquoted forms" do
      w("`(1 ,(+ 1 1) 3)").should eq("(1 2 3)")
    end

    it "splices unquote-splicing in car position" do
      w("`(1 ,@(list 2 3) 4)").should eq("(1 2 3 4)")
    end

    it "splices in the dotted tail position" do
      w("`(1 . ,(+ 1 1))").should eq("(1 . 2)")
    end

    it "supports nested quasiquote depth" do
      w("`(a `(b ,(+ 1 2)))").should eq("(a (quasiquote (b (unquote (+ 1 2)))))")
    end

    it "raises when unquote appears outside quasiquote" do
      expect_raises(LISP::LispRuntimeError, /unquote: not valid outside quasiquote/) do
        run("(unquote 1)")
      end
    end

    it "raises when unquote-splicing appears outside quasiquote" do
      expect_raises(LISP::LispRuntimeError, /unquote-splicing: not valid outside quasiquote/) do
        run("(unquote-splicing 1)")
      end
    end
  end

  describe "if" do
    it "evaluates the then-branch when true" do
      w("(if #t 1 2)").should eq("1")
    end

    it "evaluates the else-branch when false" do
      w("(if #f 1 2)").should eq("2")
    end

    it "returns nil when false with no else-branch" do
      w("(if #f 1)").should eq("()")
    end

    it "raises for the wrong arity" do
      expect_raises(LISP::LispRuntimeError, /if: expects 2 or 3 arguments/) do
        run("(if #t)")
      end
    end
  end

  describe "cond" do
    it "evaluates the first matching clause" do
      w("(cond (#f 1) (#t 2) (else 3))").should eq("2")
    end

    it "falls through to else" do
      w("(cond (#f 1) (else 3))").should eq("3")
    end

    it "returns nil when nothing matches" do
      w("(cond (#f 1))").should eq("()")
    end

    it "supports a test-only clause returning the test value" do
      w("(cond (42))").should eq("42")
    end

    it "raises on an empty clause" do
      expect_raises(LISP::LispRuntimeError, /cond: empty clause/) do
        run("(cond ())")
      end
    end
  end

  describe "when/unless" do
    it "when evaluates body when true" do
      w("(when #t 1 2)").should eq("2")
    end

    it "when returns nil when false" do
      w("(when #f 1 2)").should eq("()")
    end

    it "unless evaluates body when false" do
      w("(unless #f 1 2)").should eq("2")
    end

    it "unless returns nil when true" do
      w("(unless #t 1 2)").should eq("()")
    end

    it "raises when 'when' has no condition" do
      expect_raises(LISP::LispRuntimeError, /when: expects a condition/) do
        run("(when)")
      end
    end

    it "raises when 'unless' has no condition" do
      expect_raises(LISP::LispRuntimeError, /unless: expects a condition/) do
        run("(unless)")
      end
    end
  end

  describe "define" do
    it "defines a variable" do
      w("(define x 5) x").should eq("5")
    end

    it "defines a function via shorthand syntax" do
      w("(define (sq x) (* x x)) (sq 5)").should eq("25")
    end

    it "names an anonymous lambda when bound via define" do
      interp = LISP::Interpreter.new
      LISP.run_source(interp, "(define f (lambda (x) x))")
      interp.global.get("f").display_string.should eq("#<procedure:f>")
    end
  end

  describe "set!" do
    it "updates an existing variable" do
      w("(define x 1) (set! x 2) x").should eq("2")
    end

    it "raises for an unbound variable" do
      expect_raises(LISP::LispRuntimeError, /set!: unbound variable: y/) do
        run("(set! y 1)")
      end
    end

    it "raises when the target isn't a symbol" do
      expect_raises(LISP::LispRuntimeError, /set!: first argument must be a symbol/) do
        run("(set! 1 2)")
      end
    end
  end

  describe "lambda" do
    it "supports fixed params" do
      w("((lambda (x y) (+ x y)) 1 2)").should eq("3")
    end

    it "supports a rest param" do
      w("((lambda (a . rest) rest) 1 2 3)").should eq("(2 3)")
    end

    it "supports the λ alias" do
      w("((λ (x) x) 42)").should eq("42")
    end

    it "raises for arity mismatch" do
      expect_raises(LISP::LispRuntimeError, /expected 2 argument\(s\), got 1/) do
        run("((lambda (x y) x) 1)")
      end
    end

    it "raises for too few args with a rest param" do
      expect_raises(LISP::LispRuntimeError, /expected at least 1 argument\(s\), got 0/) do
        run("((lambda (a . rest) a))")
      end
    end
  end

  describe "let/let*/letrec" do
    it "let binds in parallel, evaluating inits in the outer scope" do
      w("(let ((a 1) (b 2)) (+ a b))").should eq("3")
    end

    it "let does not see its own bindings while evaluating inits" do
      w("(define a 10) (let ((a 1) (b a)) b)").should eq("10")
    end

    it "let* binds sequentially" do
      w("(let* ((a 1) (b (+ a 1))) (* a b))").should eq("2")
    end

    it "letrec allows mutual/self reference" do
      w("(letrec ((f (lambda (n) (if (= n 0) 1 (* n (f (- n 1))))))) (f 5))").should eq("120")
    end
  end

  describe "begin" do
    it "evaluates all forms, returning the last" do
      w("(begin 1 2 3)").should eq("3")
    end

    it "returns nil for an empty body" do
      w("(begin)").should eq("()")
    end
  end

  describe "and/or" do
    it "and returns the last value when all truthy" do
      w("(and 1 2 3)").should eq("3")
    end

    it "and short-circuits on the first falsy value" do
      w("(and 1 #f 3)").should eq("#f")
    end

    it "and with no operands is true" do
      w("(and)").should eq("#t")
    end

    it "or returns the first truthy value" do
      w("(or #f #f 7)").should eq("7")
    end

    it "or with no operands is false" do
      w("(or)").should eq("#f")
    end
  end

  describe "tail calls" do
    it "does not overflow eval depth for tail-recursive calls" do
      w("(define (sum-to n acc) (if (= n 0) acc (sum-to (- n 1) (+ acc n)))) (sum-to 100000 0)").should eq("5000050000")
    end

    it "raises recursion depth exceeded for deep non-tail recursion" do
      expect_raises(LISP::LispRuntimeError, /recursion depth exceeded/) do
        run("(define (f n) (+ 1 (f (+ n 1)))) (f 0)")
      end
    end
  end

  describe "max_eval_depth" do
    it "defaults to DEFAULT_MAX_EVAL_DEPTH" do
      LISP::Interpreter.new.max_eval_depth.should eq(LISP::Interpreter::DEFAULT_MAX_EVAL_DEPTH)
    end

    it "is configurable via the constructor" do
      LISP::Interpreter.new(max_eval_depth: 10).max_eval_depth.should eq(10)
    end

    it "is configurable after construction via the property setter" do
      interp = LISP::Interpreter.new
      interp.max_eval_depth = 10
      interp.max_eval_depth.should eq(10)
    end

    it "raises sooner when configured with a smaller depth" do
      interp = LISP::Interpreter.new(max_eval_depth: 10)
      expect_raises(LISP::LispRuntimeError, /recursion depth exceeded/) do
        LISP.run_source(interp, "(define (f n) (+ 1 (f (+ n 1)))) (f 0)")
      end
    end

    it "raises for non-tail recursion that exceeds the default depth" do
      interp = LISP::Interpreter.new
      expect_raises(LISP::LispRuntimeError, /recursion depth exceeded/) do
        LISP.run_source(interp, "(define (count-up n) (if (= n 0) 0 (+ 1 (count-up (- n 1))))) (count-up 5000)")
      end
    end

    it "allows deeper non-tail recursion when configured with a larger depth" do
      interp = LISP::Interpreter.new(max_eval_depth: 6000)
      LISP.run_source(interp, "(define (count-up n) (if (= n 0) 0 (+ 1 (count-up (- n 1))))) (count-up 5000)")
        .as(LISP::LispInt).value.should eq(5000_i64)
    end
  end

  describe "#apply" do
    it "applies a Builtin" do
      interp = LISP::Interpreter.new
      f = interp.global.get("+")
      interp.apply(f, [LISP::LispInt.new(1_i64), LISP::LispInt.new(2_i64)] of LISP::LispValue)
        .as(LISP::LispInt).value.should eq(3_i64)
    end

    it "applies a Lambda" do
      interp = LISP::Interpreter.new
      LISP.run_source(interp, "(define (sq x) (* x x))")
      f = interp.global.get("sq")
      interp.apply(f, [LISP::LispInt.new(4_i64)] of LISP::LispValue)
        .as(LISP::LispInt).value.should eq(16_i64)
    end

    it "raises when the callee isn't applicable" do
      expect_raises(LISP::LispRuntimeError, /not applicable/) do
        run("(1 2 3)")
      end
    end
  end

  describe "#parse_formals" do
    it "parses fixed params" do
      interp = LISP::Interpreter.new
      params, rest = interp.parse_formals(LISP.a_to_list([LISP::LispSym.of("a"), LISP::LispSym.of("b")] of LISP::LispValue))
      params.should eq(["a", "b"])
      rest.should be_nil
    end

    it "parses a fully variadic symbol spec" do
      interp = LISP::Interpreter.new
      params, rest = interp.parse_formals(LISP::LispSym.of("args"))
      params.should eq([] of String)
      rest.should eq("args")
    end

    it "parses a dotted rest param" do
      interp = LISP::Interpreter.new
      formals = LISP.a_to_list([LISP::LispSym.of("a")] of LISP::LispValue, LISP::LispSym.of("rest"))
      params, rest = interp.parse_formals(formals)
      params.should eq(["a"])
      rest.should eq("rest")
    end

    it "raises for a non-symbol formal" do
      interp = LISP::Interpreter.new
      formals = LISP.a_to_list([LISP::LispInt.new(1_i64)] of LISP::LispValue)
      expect_raises(LISP::LispRuntimeError, /bad formal parameter/) do
        interp.parse_formals(formals)
      end
    end
  end
end
