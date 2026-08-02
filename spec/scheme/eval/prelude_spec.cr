require "../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, src).write_string
end

describe "prelude" do
  it "caar/cadr/cddr" do
    w("(caar '((1 2) 3))").should eq("1")
    w("(cadr '(1 2 3))").should eq("2")
    w("(cddr '(1 2 3))").should eq("(3)")
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
