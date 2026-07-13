require "../../spec_helper"

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "let-values" do
  it "binds multiple values from a single (values ...) producer" do
    w("(let-values (((a b) (values 1 2))) (+ a b))").should eq("3")
  end

  it "supports multiple bindings, all initialized against the OUTER env" do
    w("(let ((a 100)) (let-values (((a b) (values 1 2)) ((c) a)) (list a b c)))").should eq("(1 2 100)")
  end

  it "supports a rest parameter" do
    w("(let-values (((a . rest) (values 1 2 3))) (list a rest))").should eq("(1 (2 3))")
  end

  it "treats a single-value producer as one value" do
    w("(let-values (((a) 5)) a)").should eq("5")
  end

  it "raises on arity mismatch" do
    expect_raises(Scheme::SchemeRuntimeError, /expected 2 value\(s\), got 1/) do
      run("(let-values (((a b) 5)) a)")
    end
  end
end

describe "let*-values" do
  it "lets later bindings see earlier ones, unlike let-values" do
    w("(let*-values (((a b) (values 1 2)) ((c) (+ a b))) (list a b c))").should eq("(1 2 3)")
  end

  it "an earlier binding is NOT visible to let-values' parallel bindings" do
    expect_raises(Scheme::SchemeRuntimeError, /unbound variable: a/) do
      run("(let-values (((a b) (values 1 2)) ((c) (+ a b))) c)")
    end
  end
end

describe "define-values" do
  it "binds multiple values at top level" do
    w("(define-values (a b) (values 1 2)) (list a b)").should eq("(1 2)")
  end

  it "binds multiple values inside a body" do
    w("(define (f) (define-values (a b) (values 1 2)) (+ a b)) (f)").should eq("3")
  end

  it "supports a rest parameter" do
    w("(define-values (a . rest) (values 1 2 3)) (list a rest)").should eq("(1 (2 3))")
  end
end

describe "let-syntax" do
  it "binds a syntax-rules macro scoped to its body" do
    w("(let-syntax ((double (syntax-rules () ((_ e) (* 2 e))))) (double 21))").should eq("42")
  end

  it "the macro is not visible outside the let-syntax body" do
    expect_raises(Scheme::SchemeRuntimeError, /unbound variable: double/) do
      run("(let-syntax ((double (syntax-rules () ((_ e) (* 2 e))))) (double 21)) (double 1)")
    end
  end
end

describe "letrec-syntax" do
  it "binds a syntax-rules macro scoped to its body" do
    w("(letrec-syntax ((double (syntax-rules () ((_ e) (* 2 e))))) (double 21))").should eq("42")
  end
end
