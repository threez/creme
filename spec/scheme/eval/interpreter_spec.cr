require "../../spec_helper"

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe Scheme::Interpreter do
  describe "quote" do
    it "returns the form unevaluated" do
      w("(quote (a b c))").should eq("(a b c)")
    end

    it "raises for the wrong number of arguments" do
      expect_raises(Scheme::SchemeRuntimeError, /quote: expects 1 argument/) do
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
      expect_raises(Scheme::SchemeRuntimeError, /unquote: not valid outside quasiquote/) do
        run("(unquote 1)")
      end
    end

    it "raises when unquote-splicing appears outside quasiquote" do
      expect_raises(Scheme::SchemeRuntimeError, /unquote-splicing: not valid outside quasiquote/) do
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
      expect_raises(Scheme::SchemeRuntimeError, /if: expects 2 or 3 arguments/) do
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
      expect_raises(Scheme::SchemeRuntimeError, /cond: empty clause/) do
        run("(cond ())")
      end
    end
  end

  describe "case" do
    it "evaluates the matching clause by eqv?" do
      w("(case 2 ((1) 'one) ((2 3) 'two-or-three) (else 'other))").should eq("two-or-three")
    end

    it "falls through to else" do
      w("(case 99 ((1) 'one) (else 'other))").should eq("other")
    end

    it "returns nil when nothing matches and there is no else" do
      w("(case 99 ((1) 'one))").should eq("()")
    end

    it "evaluates all-but-last eagerly and returns the last body form" do
      w("(case 1 ((1) 10 20 30))").should eq("30")
    end

    it "supports the => receiver clause form" do
      w("(case 3 ((3) => (lambda (x) (* x 10))) (else 'no))").should eq("30")
    end

    it "supports => in the else clause" do
      w("(case 99 ((1) 'one) (else => (lambda (x) (list 'got x))))").should eq("(got 99)")
    end

    it "matches by eqv?, not equal? (distinct strings don't match)" do
      w(%[(case "a" (("a") 'matched) (else 'no))]).should eq("no")
    end

    it "raises on an empty clause" do
      expect_raises(Scheme::SchemeRuntimeError, /case: empty clause/) do
        run("(case 1 ())")
      end
    end

    it "raises when the key expression is missing" do
      expect_raises(Scheme::SchemeRuntimeError, /case: expects a key expression/) do
        run("(case)")
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
      expect_raises(Scheme::SchemeRuntimeError, /when: expects a condition/) do
        run("(when)")
      end
    end

    it "raises when 'unless' has no condition" do
      expect_raises(Scheme::SchemeRuntimeError, /unless: expects a condition/) do
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
      interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
      Scheme.run_source(interp, "(define f (lambda (x) x))")
      interp.global.get("f").display_string.should eq("#<closure:f>")
    end
  end

  describe "set!" do
    it "updates an existing variable" do
      w("(define x 1) (set! x 2) x").should eq("2")
    end

    it "raises for an unbound variable" do
      expect_raises(Scheme::SchemeRuntimeError, /set!: unbound variable: y/) do
        run("(set! y 1)")
      end
    end

    it "raises when the target isn't a symbol" do
      expect_raises(Scheme::SchemeRuntimeError, /set!: first argument must be a symbol/) do
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
      expect_raises(Scheme::SchemeRuntimeError, /expected 2 argument\(s\), got 1/) do
        run("((lambda (x y) x) 1)")
      end
    end

    it "raises for too few args with a rest param" do
      expect_raises(Scheme::SchemeRuntimeError, /expected at least 1 argument\(s\), got 0/) do
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

  describe "named let" do
    it "loops via self-recursion, evaluating inits in the outer scope" do
      w("(let loop ((i 0) (acc 0)) (if (= i 5) acc (loop (+ i 1) (+ acc i))))").should eq("10")
    end

    it "does not leak the loop binding into the outer scope" do
      expect_raises(Scheme::SchemeRuntimeError, /unbound variable: loop/) do
        run("(let loop ((i 0)) i) (loop 1)")
      end
    end

    it "does not grow the Crystal stack across many iterations" do
      w("(let loop ((i 0)) (if (< i 100000) (loop (+ i 1)) i))").should eq("100000")
    end

    it "raises on a malformed binding" do
      expect_raises(Scheme::SchemeRuntimeError, /let: bad binding/) do
        run("(let loop ((i)) i)")
      end
    end

    it "raises on an empty body" do
      expect_raises(Scheme::SchemeRuntimeError, /let: named let body is empty/) do
        run("(let loop ())")
      end
    end
  end

  describe "do" do
    it "iterates using step expressions until the test is true, returning the result exprs" do
      w("(do ((i 0 (+ i 1)) (sum 0 (+ sum i))) ((= i 5) sum))").should eq("10")
    end

    it "evaluates commands for effect on each pass" do
      w("(define log '()) (do ((i 0 (+ i 1))) ((= i 3)) (set! log (cons i log))) (reverse log)").should eq("(0 1 2)")
    end

    it "carries forward the previous value for a var with no step" do
      w("(do ((i 0 (+ i 1)) (const 42)) ((= i 3) const))").should eq("42")
    end

    it "returns nil when the result clause is empty" do
      w("(do ((i 0 (+ i 1))) ((= i 3)))").should eq("()")
    end

    it "evaluates all-but-last result expr eagerly and returns the last" do
      w("(do ((i 0)) (#t 1 2 3))").should eq("3")
    end

    it "does not evaluate init in the loop's own scope" do
      w("(define i 99) (do ((i 0 (+ i 1))) ((= i 3) i)) i").should eq("99")
    end

    it "does not grow the Crystal stack across many iterations" do
      w("(do ((i 0 (+ i 1))) ((= i 100000) i))").should eq("100000")
    end

    it "raises on a malformed binding" do
      expect_raises(Scheme::SchemeRuntimeError, /do: bad binding/) do
        run("(do ((i 0 1 2)) (#t i))")
      end
    end

    it "raises on an empty test clause" do
      expect_raises(Scheme::SchemeRuntimeError, /do: empty test clause/) do
        run("(do ((i 0)) ())")
      end
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
      expect_raises(Scheme::SchemeRuntimeError, /recursion depth exceeded/) do
        run("(define (f n) (+ 1 (f (+ n 1)))) (f 0)")
      end
    end
  end

  describe "max_eval_depth" do
    it "defaults to DEFAULT_MAX_EVAL_DEPTH" do
      Scheme::Interpreter.new(library_search_path: ["./modules"]).max_eval_depth.should eq(Scheme::Interpreter::DEFAULT_MAX_EVAL_DEPTH)
    end

    it "is configurable via the constructor" do
      Scheme::Interpreter.new(library_search_path: ["./modules"], max_eval_depth: 10).max_eval_depth.should eq(10)
    end

    it "is configurable after construction via the property setter" do
      interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
      interp.max_eval_depth = 10
      interp.max_eval_depth.should eq(10)
    end

    it "raises sooner when configured with a smaller depth" do
      interp = Scheme::Interpreter.new(library_search_path: ["./modules"], max_eval_depth: 10)
      expect_raises(Scheme::SchemeRuntimeError, /recursion depth exceeded/) do
        Scheme.run_source(interp, "(define (f n) (+ 1 (f (+ n 1)))) (f 0)")
      end
    end

    it "raises for non-tail recursion that exceeds the default depth" do
      interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
      expect_raises(Scheme::SchemeRuntimeError, /recursion depth exceeded/) do
        Scheme.run_source(interp, "(define (count-up n) (if (= n 0) 0 (+ 1 (count-up (- n 1))))) (count-up 5000)")
      end
    end

    it "allows deeper non-tail recursion when configured with a larger depth" do
      interp = Scheme::Interpreter.new(library_search_path: ["./modules"], max_eval_depth: 6000)
      Scheme.run_source(interp, "(define (count-up n) (if (= n 0) 0 (+ 1 (count-up (- n 1))))) (count-up 5000)")
        .as(Scheme::SchemeInt).value.should eq(5000_i64)
    end
  end

  describe "max_steps" do
    it "defaults to nil (unbounded)" do
      Scheme::Interpreter.new(library_search_path: ["./modules"]).max_steps.should be_nil
    end

    it "is configurable via the constructor" do
      Scheme::Interpreter.new(library_search_path: ["./modules"], max_steps: 10).max_steps.should eq(10)
    end

    it "is configurable after construction via the property setter" do
      interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
      interp.max_steps = 10
      interp.max_steps.should eq(10)
    end

    it "raises SchemeExecutionLimitError for an infinite tail loop when set" do
      interp = Scheme::Interpreter.new(library_search_path: ["./modules"], max_steps: 1000)
      expect_raises(Scheme::SchemeExecutionLimitError, /execution step limit exceeded/) do
        Scheme.run_source(interp, "(define (f) (f)) (f)")
      end
    end

    it "does not raise for a normal script well under the limit" do
      interp = Scheme::Interpreter.new(library_search_path: ["./modules"], max_steps: 100_000)
      Scheme.run_source(interp, "(define (sq x) (* x x)) (sq 5)").as(Scheme::SchemeInt).value.should eq(25_i64)
    end

    it "does not interfere with max_eval_depth's own non-tail guard" do
      interp = Scheme::Interpreter.new(library_search_path: ["./modules"], max_eval_depth: 10, max_steps: 1_000_000)
      expect_raises(Scheme::SchemeExecutionLimitError, /recursion depth exceeded/) do
        Scheme.run_source(interp, "(define (f n) (+ 1 (f (+ n 1)))) (f 0)")
      end
    end

    it "resets its budget for each independent top-level call" do
      interp = Scheme::Interpreter.new(library_search_path: ["./modules"], max_steps: 50)
      Scheme.run_source(interp, "(+ 1 1)")
      Scheme.run_source(interp, "(+ 2 2)").as(Scheme::SchemeInt).value.should eq(4_i64)
    end
  end

  describe ".sandboxed" do
    it "denies all library imports by default" do
      Scheme::Interpreter.sandboxed.allowed_libraries.should eq([] of String)
    end

    it "sets a finite default max_steps" do
      Scheme::Interpreter.sandboxed.max_steps.should eq(100_000)
    end

    it "captures stdout by default instead of using the real STDOUT" do
      Scheme::Interpreter.sandboxed.stdout.should be_a(IO::Memory)
    end

    it "denies even (scheme base) by default: guest code must import everything itself" do
      interp = Scheme::Interpreter.sandboxed
      expect_raises(Scheme::SchemeRuntimeError, /unbound variable: \+/) do
        Scheme.run_source(interp, "(+ 1 2)")
      end
    end

    it "allows (scheme base) to be auto-bound if explicitly opted into via auto_import_base: true" do
      interp = Scheme::Interpreter.sandboxed(auto_import_base: true)
      Scheme.run_source(interp, "(+ 1 2)").as(Scheme::SchemeInt).value.should eq(3_i64)
    end

    it "still allows widening allowed_libraries explicitly" do
      interp = Scheme::Interpreter.sandboxed(allowed_libraries: ["scheme inexact"])
      Scheme.run_source(interp, "(import (scheme inexact)) (sin 0)").as(Scheme::SchemeFloat).value.should eq(0.0)
    end

    it "denies a library not in the explicit allowlist" do
      interp = Scheme::Interpreter.sandboxed(allowed_libraries: ["scheme inexact"])
      expect_raises(Scheme::SchemeRuntimeError, /import: library \(creme process\) is not permitted/) do
        Scheme.run_source(interp, "(import (creme process))")
      end
    end

    # (creme ffi) hands a guest script genuine native code execution
    # (dlopen + an arbitrary native call by name/signature) -- confirms it
    # gets no special treatment and is denied by the same allowlist gate as
    # every other library, so an embedder excluding it from allowed_
    # libraries actually works.
    it "denies (creme ffi) like any other library not in the explicit allowlist" do
      interp = Scheme::Interpreter.sandboxed(allowed_libraries: ["scheme inexact"])
      expect_raises(Scheme::SchemeRuntimeError, /import: library \(creme ffi\) is not permitted/) do
        Scheme.run_source(interp, "(import (creme ffi))")
      end
    end
  end

  describe "delay/force" do
    it "delay does not evaluate its argument eagerly" do
      w("(define ran #f) (delay (set! ran #t)) ran").should eq("#f")
    end

    it "force evaluates and returns the delayed value" do
      w("(import (scheme lazy)) (force (delay (+ 1 2)))").should eq("3")
    end

    it "force memoizes: the thunk runs only once" do
      w("(import (scheme lazy)) (define n 0) (define p (delay (begin (set! n (+ n 1)) n))) (force p) (force p) n").should eq("1")
    end

    it "force on a non-promise returns it unchanged" do
      w("(import (scheme lazy)) (force 42)").should eq("42")
    end

    it "promise? recognizes promises" do
      w("(import (scheme lazy)) (promise? (delay 1))").should eq("#t")
      w("(import (scheme lazy)) (promise? 1)").should eq("#f")
    end

    it "make-promise wraps a plain value as an already-forced promise" do
      w("(import (scheme lazy)) (force (make-promise 5))").should eq("5")
    end

    it "make-promise passes an existing promise through unchanged" do
      w("(import (scheme lazy)) (define p (delay 5)) (eq? (make-promise p) p)").should eq("#t")
    end

    it "raises for the wrong number of arguments" do
      expect_raises(Scheme::SchemeRuntimeError, /delay: expects 1 argument/) do
        run("(delay)")
      end
    end
  end

  describe "#apply" do
    it "applies a Builtin" do
      interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
      f = interp.global.get("+")
      interp.apply(f, [Scheme::SchemeInt.new(1_i64), Scheme::SchemeInt.new(2_i64)] of Scheme::SchemeValue)
        .as(Scheme::SchemeInt).value.should eq(3_i64)
    end

    it "applies a Lambda" do
      interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
      Scheme.run_source(interp, "(define (sq x) (* x x))")
      f = interp.global.get("sq")
      interp.apply(f, [Scheme::SchemeInt.new(4_i64)] of Scheme::SchemeValue)
        .as(Scheme::SchemeInt).value.should eq(16_i64)
    end

    it "raises when the callee isn't applicable" do
      expect_raises(Scheme::SchemeRuntimeError, /not applicable/) do
        run("(1 2 3)")
      end
    end
  end

  describe "#parse_formals" do
    it "parses fixed params" do
      interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
      params, rest = interp.parse_formals(Scheme.a_to_list([Scheme::SchemeSym.of("a"), Scheme::SchemeSym.of("b")] of Scheme::SchemeValue))
      params.should eq(["a", "b"])
      rest.should be_nil
    end

    it "parses a fully variadic symbol spec" do
      interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
      params, rest = interp.parse_formals(Scheme::SchemeSym.of("args"))
      params.should eq([] of String)
      rest.should eq("args")
    end

    it "parses a dotted rest param" do
      interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
      formals = Scheme.a_to_list([Scheme::SchemeSym.of("a")] of Scheme::SchemeValue, Scheme::SchemeSym.of("rest"))
      params, rest = interp.parse_formals(formals)
      params.should eq(["a"])
      rest.should eq("rest")
    end

    it "raises for a non-symbol formal" do
      interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
      formals = Scheme.a_to_list([Scheme::SchemeInt.new(1_i64)] of Scheme::SchemeValue)
      expect_raises(Scheme::SchemeRuntimeError, /bad formal parameter/) do
        interp.parse_formals(formals)
      end
    end
  end
end
