require "../../spec_helper"

private def w(src : String) : String
  interp = LISP::Interpreter.new
  LISP.run_source(interp, "(require 'string) #{src}").write_string
end

private def run(src : String) : LISP::LispValue
  interp = LISP::Interpreter.new
  LISP.run_source(interp, "(require 'string) #{src}")
end

describe "string module" do
  it "upcases, downcases, trims, reverses" do
    w(%((string:upcase "abc"))).should eq(%("ABC"))
    w(%((string:downcase "ABC"))).should eq(%("abc"))
    w(%((string:trim "  hi  "))).should eq(%("hi"))
    w(%((string:reverse "abc"))).should eq(%("cba"))
  end

  it "splits and joins" do
    w(%((string:split "a,b,c" ","))).should eq(%(("a" "b" "c")))
    w(%((string:join (list "a" "b" "c") "-"))).should eq(%("a-b-c"))
  end

  it "checks contains?/starts-with?/ends-with?/index-of" do
    w(%((string:contains? "hello" "ell"))).should eq("#t")
    w(%((string:starts-with? "hello" "he"))).should eq("#t")
    w(%((string:ends-with? "hello" "lo"))).should eq("#t")
    w(%((string:index-of "hello" "l"))).should eq("2")
    w(%((string:index-of "hello" "z"))).should eq("#f")
  end

  it "explodes into chars, repeats, and pads" do
    w(%((string:chars "ab"))).should eq("(#\\a #\\b)")
    w(%((string:repeat "ab" 3))).should eq(%("ababab"))
    w(%((string:pad-left "7" 3 "0"))).should eq(%("007"))
    w(%((string:pad-right "7" 3 "0"))).should eq(%("700"))
  end

  it "raises on non-string arguments" do
    expect_raises(LISP::LispRuntimeError, /string:upcase: expected string/) do
      run("(string:upcase 5)")
    end
  end
end
