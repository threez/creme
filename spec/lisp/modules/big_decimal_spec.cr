require "../../spec_helper"

private def w(src : String) : String
  interp = LISP::Interpreter.new
  LISP.run_source(interp, "(require 'bigdecimal) #{src}").write_string
end

private def run(src : String) : LISP::LispValue
  interp = LISP::Interpreter.new
  LISP.run_source(interp, "(require 'bigdecimal) #{src}")
end

describe "bigdecimal module" do
  it "parses and adds" do
    w(%((bigdecimal:to-string (bigdecimal:add (bigdecimal:parse "1.1") (bigdecimal:parse "2.2"))))).should eq(%("3.3"))
  end

  it "subtracts, multiplies, divides" do
    w(%((bigdecimal:to-string (bigdecimal:sub (bigdecimal:parse "5") (bigdecimal:parse "2"))))).should eq(%("3.0"))
    w(%((bigdecimal:to-string (bigdecimal:mul (bigdecimal:parse "2") (bigdecimal:parse "3"))))).should eq(%("6.0"))
    w(%((bigdecimal:to-string (bigdecimal:div (bigdecimal:parse "6") (bigdecimal:parse "2"))))).should eq(%("3.0"))
  end

  it "compares" do
    w(%((bigdecimal:< (bigdecimal:parse "1") (bigdecimal:parse "2")))).should eq("#t")
    w(%((bigdecimal:= (bigdecimal:parse "1.0") (bigdecimal:parse "1.0")))).should eq("#t")
  end

  it "raises on division by zero" do
    expect_raises(LISP::LispRuntimeError, /bigdecimal:div: division by zero/) do
      run(%((bigdecimal:div (bigdecimal:parse "1") (bigdecimal:parse "0"))))
    end
  end

  it "raises on invalid decimal strings" do
    expect_raises(LISP::LispRuntimeError, /bigdecimal:parse: invalid decimal/) do
      run(%((bigdecimal:parse "not-a-number")))
    end
  end
end
