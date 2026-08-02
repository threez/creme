require "../../spec_helper"

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "call/cc" do
  it "invoking the continuation escapes with the given value" do
    w("(call/cc (lambda (k) (+ 1 (k 42))))").should eq("42")
  end

  it "both call/cc and call-with-current-continuation work" do
    w("(call-with-current-continuation (lambda (k) (+ 1 (k 99))))").should eq("99")
  end

  it "not invoking the continuation returns the body's value normally" do
    w("(+ 1 (call/cc (lambda (k) 10)))").should eq("11")
  end

  it "escapes early from a for-each loop" do
    src = <<-SCHEME
      (call/cc (lambda (return)
        (for-each (lambda (x) (if (> x 3) (return x))) '(1 2 3 4 5))
        'not-found))
      SCHEME
    w(src).should eq("4")
  end

  it "escapes early from nested recursion" do
    src = <<-SCHEME
      (define (find-first pred lst k)
        (cond ((null? lst) #f)
              ((pred (car lst)) (k (car lst)))
              (else (find-first pred (cdr lst) k))))
      (call/cc (lambda (return) (find-first even? '(1 3 5 6 7) return)))
      SCHEME
    w(src).should eq("6")
  end

  it "a nested call/cc's escape is not caught by an outer call/cc's rescue" do
    src = "(call/cc (lambda (outer) (+ 1 (call/cc (lambda (inner) (outer 100))))))"
    w(src).should eq("100")
  end

  it "an inner call/cc that doesn't escape still returns normally to the outer" do
    src = "(call/cc (lambda (outer) (+ 1 (call/cc (lambda (inner) 5)))))"
    w(src).should eq("6")
  end

  it "a continuation invoked from inside a guard body is not caught by that guard" do
    src = <<-SCHEME
      (call/cc (lambda (k)
        (guard (e (#t 'guard-caught-it))
          (k 'escaped-past-guard))))
      SCHEME
    w(src).should eq("escaped-past-guard")
  end

  it "a continuation invoked from inside a parameterize body still triggers the restore" do
    src = <<-SCHEME
      (define p (make-parameter 10))
      (call/cc (lambda (k)
        (parameterize ((p 20))
          (k 'escaped))))
      SCHEME
    w(src).should eq("escaped")
  end

  it "parameterize's restore fires correctly even after the escape" do
    interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
    Scheme.run_source(interp, "(define p (make-parameter 10))")
    Scheme.run_source(interp, "(call/cc (lambda (k) (parameterize ((p 20)) (k 'escaped))))")
    Scheme.run_source(interp, "(p)").write_string.should eq("10")
  end

  it "raises when the continuation is invoked with the wrong number of arguments" do
    expect_raises(Scheme::SchemeRuntimeError, /continuation: expected 1 argument, got 2/) do
      run("(call/cc (lambda (k) (k 1 2)))")
    end
  end

  it "raises when a continuation is invoked outside its dynamic extent" do
    src = <<-SCHEME
      (define saved-k #f)
      (call/cc (lambda (k) (set! saved-k k) 'initial))
      (saved-k 'late-value)
      SCHEME
    expect_raises(Scheme::SchemeRuntimeError, /continuation invoked outside its dynamic extent/) do
      run(src)
    end
  end

  it "the interpreter remains usable after a stale continuation invocation raises" do
    interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
    Scheme.run_source(interp, "(define saved-k #f)")
    Scheme.run_source(interp, "(call/cc (lambda (k) (set! saved-k k) 'initial))")
    expect_raises(Scheme::SchemeRuntimeError) do
      Scheme.run_source(interp, "(saved-k 'late-value)")
    end
    Scheme.run_source(interp, "(+ 1 2)").write_string.should eq("3")
  end
end
