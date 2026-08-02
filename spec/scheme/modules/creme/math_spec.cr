require "../../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme math)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme math)) #{src}")
end

describe "math module" do
  it "computes trig and log functions" do
    w("(sin 0)").should eq("0.0")
    w("(cos 0)").should eq("1.0")
    w("(log e)").should eq("1.0")
  end

  it "exposes pi and e as constants" do
    # Compared against Crystal's own Math::PI/Math::E.to_s (rather than a
    # hardcoded literal) since Float64's shortest-round-trip string
    # representation is a stdlib/version detail, not something this project
    # controls — a hardcoded expectation drifts whenever that changes.
    w("pi").should eq(Math::PI.to_s)
    w("e").should eq(Math::E.to_s)
  end

  it "computes pow, atan2, and hypot" do
    w("(pow 2 10)").should eq("1024.0")
    w("(hypot 3 4)").should eq("5.0")
  end

  it "raises when given a non-number" do
    expect_raises(Scheme::SchemeRuntimeError, /sin: expected number/) do
      run(%((sin "x")))
    end
  end

  it "round-trips a float through its raw IEEE754 bit pattern" do
    w("(flonum->bits 1.0)").should eq("4607182418800017408")
    w("(bits->flonum (flonum->bits 3.14))").should eq("3.14")
    w("(bits->flonum (flonum->bits +inf.0))").should eq("+inf.0")
    w("(bits->flonum (flonum->bits -inf.0))").should eq("-inf.0")
    w("(bits->flonum (flonum->bits +nan.0))").should eq("+nan.0")
  end
end
