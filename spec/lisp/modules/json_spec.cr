require "../../spec_helper"

private def w(src : String) : String
  interp = LISP::Interpreter.new
  LISP.run_source(interp, "(require 'json) #{src}").write_string
end

private def run(src : String) : LISP::LispValue
  interp = LISP::Interpreter.new
  LISP.run_source(interp, "(require 'json) #{src}")
end

describe "json module" do
  it "parses arrays into vectors" do
    w(%((json:parse "[1, 2.5, \\"a\\", true, null]"))).should eq(%(#(1 2.5 "a" #t ())))
  end

  it "parses objects into an alist accessible via assoc/cdr" do
    w(%((cdr (assoc "a" (json:parse "{\\"a\\":1}"))))).should eq("1")
  end

  it "returns #f from assoc for a missing key" do
    w(%((assoc "z" (json:parse "{\\"a\\":1}")))).should eq("#f")
  end

  it "round-trips stringify for objects and arrays" do
    w(%((json:stringify (json:parse "{\\"a\\":1,\\"b\\":[1,2]}")))).should eq("\"{\\\"a\\\":1,\\\"b\\\":[1,2]}\"")
    w(%((json:stringify (json:parse "[1,2,3]")))).should eq(%("[1,2,3]"))
  end

  it "mutates an object entry in place with set-cdr!" do
    w(%((let ((o (json:parse "{\\"x\\":1}"))) (set-cdr! (assoc "x" o) 2) (cdr (assoc "x" o))))).should eq("2")
  end

  it "stringifies a plain list as a JSON array" do
    w(%((json:stringify (list 1 2 3)))).should eq(%("[1,2,3]"))
  end

  it "conflates an empty object with null (accepted tradeoff of using plain NIL for both)" do
    w(%((json:parse "{}"))).should eq("()")
    w(%((json:stringify (json:parse "{}")))).should eq(%("null"))
  end

  it "raises on malformed json" do
    expect_raises(LISP::LispRuntimeError, /json:parse: invalid json/) do
      run(%((json:parse "{not json")))
    end
  end

  it "stringifies a char as a 1-character string" do
    w(%((json:stringify #\\a))).should eq("\"\\\"a\\\"\"")
  end
end
