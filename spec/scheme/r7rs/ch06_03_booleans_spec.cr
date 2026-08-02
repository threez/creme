require "../../spec_helper"

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "R7RS §6.3 Booleans" do
  it "#t and #f are the standard boolean objects; #true/#false are alternative spellings" do
    w("#t").should eq("#t")
    w("#f").should eq("#f")
    w("#true").should eq("#t")
    w("#false").should eq("#f")
  end

  it "not returns #t only for #f, and #f otherwise (including for '() and other Lisp-falsy-looking values)" do
    w("(list (not #t) (not 3) (not (list 3)) (not #f) (not '()) (not (list)) (not 'nil))").should eq("(#f #f #f #t #f #f #f)")
  end

  it "boolean? recognizes only #t/#f, not 0 or ()" do
    w("(list (boolean? #f) (boolean? 0) (boolean? '()))").should eq("(#t #f #f)")
  end

  it "boolean=? returns #t if all arguments are booleans and all are #t or all are #f" do
    w("(boolean=? #t #t #t)").should eq("#t")
    w("(boolean=? #t #f)").should eq("#f")
  end
end
