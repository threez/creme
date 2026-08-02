require "../../spec_helper"

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "truncate-quotient / truncate-remainder" do
  it "truncate toward zero, same as quotient/remainder" do
    w("(truncate-quotient 7 2)").should eq("3")
    w("(truncate-remainder 7 2)").should eq("1")
    w("(truncate-quotient -7 2)").should eq("-3")
    w("(truncate-remainder -7 2)").should eq("-1")
  end
end

describe "floor-quotient / floor-remainder" do
  it "floor toward negative infinity, same as modulo's sign convention" do
    w("(floor-quotient 7 2)").should eq("3")
    w("(floor-remainder 7 2)").should eq("1")
    w("(floor-quotient -7 2)").should eq("-4")
    w("(floor-remainder -7 2)").should eq("1")
  end
end

describe "truncate/ and floor/" do
  it "return both quotient and remainder via values" do
    w("(call-with-values (lambda () (truncate/ 7 2)) list)").should eq("(3 1)")
    w("(call-with-values (lambda () (floor/ -7 2)) list)").should eq("(-4 1)")
  end
end

describe "rationalize" do
  it "returns the simplest exact rational within epsilon, for exact inputs" do
    w("(rationalize (/ 1 3) (/ 1 100))").should eq("1/3")
  end

  it "returns an inexact result when either input is inexact" do
    w("(inexact? (rationalize .3 (/ 1 10)))").should eq("#t")
  end

  it "0 is simplest when the interval spans zero" do
    w("(rationalize (/ 1 100) (/ 1 10))").should eq("0")
  end
end

describe "syntax-error" do
  it "raises an error usable with guard, same as (error ...)" do
    w(%[(guard (e (#t (list (error-object-message e) (error-object-irritants e)))) (syntax-error "bad form" 'x))]).should eq(%(("bad form" (x))))
  end
end
