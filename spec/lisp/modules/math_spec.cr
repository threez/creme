require "../../spec_helper"

private def w(src : String) : String
  interp = LISP::Interpreter.new
  LISP.run_source(interp, "(require 'math) #{src}").write_string
end

private def run(src : String) : LISP::LispValue
  interp = LISP::Interpreter.new
  LISP.run_source(interp, "(require 'math) #{src}")
end

describe "math module" do
  it "computes trig and log functions" do
    w("(math:sin 0)").should eq("0.0")
    w("(math:cos 0)").should eq("1.0")
    w("(math:log math:e)").should eq("1.0")
  end

  it "exposes pi and e as constants" do
    w("math:pi").should eq("3.141592653589793")
    w("math:e").should eq("2.718281828459045")
  end

  it "computes pow, atan2, and hypot" do
    w("(math:pow 2 10)").should eq("1024.0")
    w("(math:hypot 3 4)").should eq("5.0")
  end

  it "raises when given a non-number" do
    expect_raises(LISP::LispRuntimeError, /math:sin: expected number/) do
      run(%((math:sin "x")))
    end
  end
end
