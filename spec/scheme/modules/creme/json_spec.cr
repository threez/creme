require "../../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme json)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme json)) #{src}")
end

describe "json module" do
  it "parses arrays into vectors" do
    w(%((json-read "[1, 2.5, \\"a\\", true, null]"))).should eq(%(#(1 2.5 "a" #t ())))
  end

  it "parses objects into an alist accessible via assoc/cdr" do
    w(%((cdr (assoc "a" (json-read "{\\"a\\":1}"))))).should eq("1")
  end

  it "returns #f from assoc for a missing key" do
    w(%((assoc "z" (json-read "{\\"a\\":1}")))).should eq("#f")
  end

  it "round-trips stringify for objects and arrays" do
    w(%((json-write (json-read "{\\"a\\":1,\\"b\\":[1,2]}")))).should eq("\"{\\\"a\\\":1,\\\"b\\\":[1,2]}\"")
    w(%((json-write (json-read "[1,2,3]")))).should eq(%("[1,2,3]"))
  end

  it "mutates an object entry in place with set-cdr!" do
    w(%((let ((o (json-read "{\\"x\\":1}"))) (set-cdr! (assoc "x" o) 2) (cdr (assoc "x" o))))).should eq("2")
  end

  it "stringifies a plain list as a JSON array" do
    w(%((json-write (list 1 2 3)))).should eq(%("[1,2,3]"))
  end

  it "conflates an empty object with null (accepted tradeoff of using plain NIL for both)" do
    w(%((json-read "{}"))).should eq("()")
    w(%((json-write (json-read "{}")))).should eq(%("null"))
  end

  it "raises on malformed json" do
    expect_raises(Scheme::SchemeRuntimeError, /json-read: invalid json/) do
      run(%((json-read "{not json")))
    end
  end

  it "stringifies a char as a 1-character string" do
    w(%((json-write #\\a))).should eq("\"\\\"a\\\"\"")
  end
end
