require "../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, "(import (creme math)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, "(import (creme math)) #{src}")
end

describe "math module" do
  it "computes trig and log functions" do
    w("(sin 0)").should eq("0.0")
    w("(cos 0)").should eq("1.0")
    w("(log e)").should eq("1.0")
  end

  it "exposes pi and e as constants" do
    w("pi").should eq("3.141592653589793")
    w("e").should eq("2.7182818284590455")
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
end
