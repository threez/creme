require "../../spec_helper"

private def w(src : String) : String
  interp = LISP::Interpreter.new
  LISP.run_source(interp, src).write_string
end

describe "prelude" do
  it "caar/cadr/cddr/caddr/cdddr/cadddr" do
    w("(caar '((1 2) 3))").should eq("1")
    w("(cadr '(1 2 3))").should eq("2")
    w("(cddr '(1 2 3))").should eq("(3)")
    w("(caddr '(1 2 3))").should eq("3")
    w("(cdddr '(1 2 3 4))").should eq("(4)")
    w("(cadddr '(1 2 3 4))").should eq("4")
  end

  it "first/second/third/rest" do
    w("(first '(1 2 3))").should eq("1")
    w("(second '(1 2 3))").should eq("2")
    w("(third '(1 2 3))").should eq("3")
    w("(rest '(1 2 3))").should eq("(2 3)")
  end

  it "zero?/positive?/negative?" do
    w("(zero? 0)").should eq("#t")
    w("(zero? 1)").should eq("#f")
    w("(positive? 1)").should eq("#t")
    w("(positive? -1)").should eq("#f")
    w("(negative? -1)").should eq("#t")
    w("(negative? 1)").should eq("#f")
  end

  it "even?/odd?" do
    w("(even? 10)").should eq("#t")
    w("(odd? 7)").should eq("#t")
    w("(even? 7)").should eq("#f")
  end

  it "add1/sub1/1+" do
    w("(add1 1)").should eq("2")
    w("(sub1 1)").should eq("0")
    w("(1+ 1)").should eq("2")
  end

  it "identity returns its argument" do
    w("(identity 42)").should eq("42")
  end

  it "range produces a half-open list of integers" do
    w("(range 1 5)").should eq("(1 2 3 4)")
  end

  it "range produces an empty list when a >= b" do
    w("(range 3 3)").should eq("()")
  end

  it "last returns the final element" do
    w("(last '(1 2 3))").should eq("3")
  end

  it "assoc finds a matching key" do
    w("(assoc 'b '((a . 1) (b . 2)))").should eq("(b . 2)")
  end

  it "assoc returns #f when not found" do
    w("(assoc 'z '((a . 1) (b . 2)))").should eq("#f")
  end

  it "member finds a matching element and returns the tail" do
    w("(member 2 '(1 2 3))").should eq("(2 3)")
  end

  it "member returns #f when not found" do
    w("(member 9 '(1 2 3))").should eq("#f")
  end
end
