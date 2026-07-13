require "../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, "(import (creme regex)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, "(import (creme regex)) #{src}")
end

describe "regex module" do
  it "matches and reports matches?" do
    w(%((regexp-matches? (regexp "[0-9]+") "abc123"))).should eq("#t")
    w(%((regexp-matches? (regexp "[0-9]+") "abc"))).should eq("#f")
  end

  it "returns capture groups on search, #f otherwise" do
    w(%((regexp-search (regexp "([a-z]+)([0-9]+)") "abc123"))).should eq(%(("abc123" "abc" "123")))
    w(%((regexp-search (regexp "[0-9]+") "abc"))).should eq("#f")
  end

  it "extracts all matches" do
    w(%((regexp-extract (regexp "[0-9]+") "a1b22c333"))).should eq(%((("1") ("22") ("333"))))
  end

  it "replaces first and all matches" do
    w(%((regexp-replace (regexp "[0-9]+") "X" "a1b2"))).should eq(%("aXb2"))
    w(%((regexp-replace-all (regexp "[0-9]+") "X" "a1b2"))).should eq(%("aXbX"))
  end

  it "splits on a pattern" do
    w(%((regexp-split (regexp ",[ ]*") "a, b,c"))).should eq(%(("a" "b" "c")))
  end

  it "raises on an invalid pattern" do
    expect_raises(Scheme::SchemeRuntimeError, /regexp: invalid pattern/) do
      run("(regexp \"(\")")
    end
  end
end
