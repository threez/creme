require "../../spec_helper"

private def w(src : String) : String
  interp = LISP::Interpreter.new
  LISP.run_source(interp, "(require 'regex) #{src}").write_string
end

private def run(src : String) : LISP::LispValue
  interp = LISP::Interpreter.new
  LISP.run_source(interp, "(require 'regex) #{src}")
end

describe "regex module" do
  it "matches and reports match?" do
    w(%((regex:match? (regex:compile "[0-9]+") "abc123"))).should eq("#t")
    w(%((regex:match? (regex:compile "[0-9]+") "abc"))).should eq("#f")
  end

  it "returns capture groups on match, #f otherwise" do
    w(%((regex:match (regex:compile "([a-z]+)([0-9]+)") "abc123"))).should eq(%(("abc123" "abc" "123")))
    w(%((regex:match (regex:compile "[0-9]+") "abc"))).should eq("#f")
  end

  it "finds all matches" do
    w(%((regex:find-all (regex:compile "[0-9]+") "a1b22c333"))).should eq(%((("1") ("22") ("333"))))
  end

  it "replaces first and all matches" do
    w(%((regex:replace (regex:compile "[0-9]+") "X" "a1b2"))).should eq(%("aXb2"))
    w(%((regex:replace-all (regex:compile "[0-9]+") "X" "a1b2"))).should eq(%("aXbX"))
  end

  it "splits on a pattern" do
    w(%((regex:split (regex:compile ",[ ]*") "a, b,c"))).should eq(%(("a" "b" "c")))
  end

  it "raises on an invalid pattern" do
    expect_raises(LISP::LispRuntimeError, /regex:compile: invalid pattern/) do
      run("(regex:compile \"(\")")
    end
  end
end
