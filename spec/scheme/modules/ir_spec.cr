require "../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (scheme base) (scheme write) (scheme eval) (creme ir)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (scheme base) (scheme write) (scheme eval) (creme ir)) #{src}")
end

describe "ir module" do
  it "filters a list" do
    w(%[(filter odd? '(1 2 3 4 5))]).should eq("(1 3 5)")
  end

  it "maps with a 0-based index" do
    w(%[(map-indexed (lambda (x i) (list x i)) '(a b c))])
      .should eq("((a 0) (b 1) (c 2))")
  end

  it "generates fresh, distinct gensym-var symbols" do
    run(%[(eq? (gensym-var "x") (gensym-var "x"))]).write_string.should eq("#f")
  end

  it "builds data/application forms" do
    w(%[(gen-quote 42)]).should eq("(quote 42)")
    w(%[(gen-call 'foo 'a 'b)]).should eq("(foo a b)")
    w(%[(gen-value-list (list 'a 'b))]).should eq("(list a b)")
    w(%[(gen-cons 'a 'b)]).should eq("(cons a b)")
    w(%[(gen-vector (list 'a 'b))]).should eq("(vector a b)")
    w(%[(gen-vector-ref 'v 2)]).should eq("(vector-ref v 2)")
    w(%[(gen-vector-set! 'v 2 'x)]).should eq("(vector-set! v 2 x)")
  end

  it "builds binding forms" do
    w(%[(gen-let (list (list 'x 1)) '(display x))]).should eq("(let ((x 1)) (display x))")
    w(%[(gen-let* (list (list 'x 1) (list 'y 2)) '(+ x y))]).should eq("(let* ((x 1) (y 2)) (+ x y))")
    w(%[(gen-letrec (list (list 'x 1)) 'x)]).should eq("(letrec ((x 1)) x)")
    w(%[(gen-named-let 'loop (list (list 'x 0)) '(loop))]).should eq("(let loop ((x 0)) (loop))")
    w(%[(gen-lambda (list 'x 'y) '(+ x y))]).should eq("(lambda (x y) (+ x y))")
    w(%[(gen-define 'x 1)]).should eq("(define x 1)")
    w(%[(gen-define (list 'f 'a) '(+ a 1))]).should eq("(define (f a) (+ a 1))")
  end

  it "builds control-flow forms" do
    w(%[(gen-if 'test 'then)]).should eq("(if test then)")
    w(%[(gen-if 'test 'then 'else)]).should eq("(if test then else)")
    w(%[(gen-when 'test 'a 'b)]).should eq("(when test a b)")
    w(%[(gen-unless 'test 'a)]).should eq("(unless test a)")
    w(%[(gen-cond (list (list 'a 1) (list 'else 2)))]).should eq("(cond (a 1) (else 2))")
    w(%[(gen-case 'x (list (list (list 1) 'one) (list (list 'else) 'other)))])
      .should eq("(case x ((1) one) ((else) other))")
    w(%[(gen-and (list 'a 'b))]).should eq("(and a b)")
    w(%[(gen-or (list 'a 'b))]).should eq("(or a b)")
    w(%[(gen-begin (list 'a 'b))]).should eq("(begin a b)")
    w(%[(gen-begin (list 'a))]).should eq("a")
    w(%[(gen-do (list (list 'i 0 '(+ i 1))) (list '(= i 3) 'i) '(display i))])
      .should eq("(do ((i 0 (+ i 1))) ((= i 3) i) (display i))")
  end

  it "builds an assignment form" do
    w(%[(gen-set! 'x 1)]).should eq("(set! x 1)")
  end

  it "generates code that evaluates to the right value once assembled" do
    run(%[(eval (gen-if (gen-quote #t) (gen-quote 1) (gen-quote 2)))]).write_string.should eq("1")
    run(%[(eval (gen-let (list (list 'x (gen-quote 1))) (gen-call '+ 'x (gen-quote 2))))]).write_string.should eq("3")
  end
end
