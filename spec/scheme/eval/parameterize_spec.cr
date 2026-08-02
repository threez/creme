require "../../spec_helper"

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "make-parameter/parameterize" do
  it "calling a parameter with no arguments reads its current value" do
    w("(define p (make-parameter 10)) (p)").should eq("10")
  end

  it "parameterize rebinds for the dynamic extent of its body" do
    w("(define p (make-parameter 10)) (parameterize ((p 20)) (p))").should eq("20")
  end

  it "restores the previous value after the body completes" do
    w("(define p (make-parameter 10)) (parameterize ((p 20)) (p)) (p)").should eq("10")
  end

  it "restores the previous value even when the body raises" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    Creme.run_source(interp, "(define p (make-parameter 10))")
    expect_raises(Creme::SchemeUserError) do
      Creme.run_source(interp, %[(parameterize ((p 20)) (error "boom"))])
    end
    Creme.run_source(interp, "(p)").write_string.should eq("10")
  end

  it "supports nested parameterize" do
    src = <<-SCHEME
      (define p (make-parameter 1))
      (parameterize ((p 2))
        (list (p) (parameterize ((p 3)) (p)) (p)))
      SCHEME
    w(src).should eq("(2 3 2)")
  end

  it "applies the converter to the initial value" do
    w("(define p (make-parameter 5 (lambda (x) (* x 10)))) (p)").should eq("50")
  end

  it "applies the converter on every parameterize rebind" do
    w("(define p (make-parameter 5 (lambda (x) (* x 10)))) (parameterize ((p 2)) (p))").should eq("20")
  end

  it "raises when calling a parameter with an argument" do
    expect_raises(Creme::SchemeRuntimeError, /parameter: expected 0 arguments, got 1/) do
      run("(define p (make-parameter 10)) (p 20)")
    end
  end

  it "raises when parameterize is given a non-parameter" do
    expect_raises(Creme::SchemeRuntimeError, /parameterize: expected a parameter object/) do
      run("(parameterize ((+ 1)) 1)")
    end
  end

  it "raises on a malformed binding" do
    expect_raises(Creme::SchemeRuntimeError, /parameterize: bad binding/) do
      run("(define p (make-parameter 10)) (parameterize ((p)) 1)")
    end
  end
end
