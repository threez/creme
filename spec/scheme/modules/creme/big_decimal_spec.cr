require "../../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, "(import (creme bigdecimal)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, "(import (creme bigdecimal)) #{src}")
end

describe "bigdecimal module" do
  it "parses and adds" do
    w(%((bigdecimal->string (bigdecimal-add (string->bigdecimal "1.1") (string->bigdecimal "2.2"))))).should eq(%("3.3"))
  end

  it "subtracts, multiplies, divides" do
    w(%((bigdecimal->string (bigdecimal-sub (string->bigdecimal "5") (string->bigdecimal "2"))))).should eq(%("3.0"))
    w(%((bigdecimal->string (bigdecimal-mul (string->bigdecimal "2") (string->bigdecimal "3"))))).should eq(%("6.0"))
    w(%((bigdecimal->string (bigdecimal-div (string->bigdecimal "6") (string->bigdecimal "2"))))).should eq(%("3.0"))
  end

  it "compares" do
    w(%((bigdecimal<? (string->bigdecimal "1") (string->bigdecimal "2")))).should eq("#t")
    w(%((bigdecimal=? (string->bigdecimal "1.0") (string->bigdecimal "1.0")))).should eq("#t")
  end

  it "raises on division by zero" do
    expect_raises(Scheme::SchemeRuntimeError, /bigdecimal-div: division by zero/) do
      run(%((bigdecimal-div (string->bigdecimal "1") (string->bigdecimal "0"))))
    end
  end

  it "raises on invalid decimal strings" do
    expect_raises(Scheme::SchemeRuntimeError, /string->bigdecimal: invalid decimal/) do
      run(%((string->bigdecimal "not-a-number")))
    end
  end
end
