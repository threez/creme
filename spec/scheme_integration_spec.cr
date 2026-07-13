require "./spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, src).write_string
end

describe "integration: examples/demo.scm scenarios" do
  it "recursive factorial" do
    w("(define (fact n) (if (<= n 1) 1 (* n (fact (- n 1))))) (fact 10)").should eq("3628800")
  end

  it "recursive fibonacci" do
    w("(define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (fib 20)").should eq("6765")
  end

  it "closures with let + set! (a stateful counter)" do
    w(<<-SCHEME).should eq("3")
      (define (make-counter)
        (let ((n 0))
          (lambda () (set! n (+ n 1)) n)))
      (define c (make-counter))
      (c) (c) (c)
      SCHEME
  end

  it "curried adder closures" do
    w("(define (make-adder n) (lambda (x) (+ x n))) ((make-adder 3) 4)").should eq("7")
  end

  it "map/filter/reduce pipeline" do
    w("(map (lambda (x) (* x x)) '(1 2 3 4))").should eq("(1 4 9 16)")
    w("(import (creme extra)) (filter (lambda (x) (> x 2)) '(1 2 3 4))").should eq("(3 4)")
    w("(import (creme extra)) (reduce + 0 '(1 2 3 4 5))").should eq("15")
  end

  it "let and let*" do
    w("(let ((a 1) (b 2)) (+ a b))").should eq("3")
    w("(let* ((a 1) (b (+ a 1))) (* a b))").should eq("2")
  end

  it "cond with else, returning a quoted symbol" do
    w("(define (sign x) (cond ((> x 0) 'positive) ((< x 0) 'negative) (else 'zero))) (sign -5)").should eq("negative")
  end

  it "even?/odd? prelude predicates" do
    w("(even? 10)").should eq("#t")
    w("(odd? 7)").should eq("#t")
  end

  it "tail-recursive sum-to 100000 does not overflow the stack" do
    w("(define (sum-to n acc) (if (= n 0) acc (sum-to (- n 1) (+ acc n)))) (sum-to 100000 0)").should eq("5000050000")
  end

  it "mixed int/float arithmetic" do
    w("(+ 1 2.5 3)").should eq("6.5")
  end

  it "chained comparison" do
    w("(< 1 2 3)").should eq("#t")
  end

  it "and/or short-circuit" do
    w("(and 1 2 3)").should eq("3")
    w("(or #f #f 7)").should eq("7")
  end

  it "quasiquote with unquote and unquote-splicing" do
    w("`(1 ,(+ 1 1) ,@(list 3 4))").should eq("(1 2 3 4)")
  end

  it "list ops: append/length/reverse" do
    w("(append '(1 2) '(3 4))").should eq("(1 2 3 4)")
    w("(length '(a b c))").should eq("3")
    w("(reverse '(1 2 3))").should eq("(3 2 1)")
  end

  it "runs examples/demo.scm end to end without raising" do
    interp = Scheme::Interpreter.new
    Scheme.run_file(interp, "examples/demo.scm")
  end
end
