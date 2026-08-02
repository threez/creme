require "../../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (scheme base) (creme reader)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (scheme base) (creme reader)) #{src}")
end

describe "(creme reader)" do
  it "round-trips ordinary forms through lex-tokens + tokens->forms unchanged" do
    ["(f x y)", "(define (add x y) (+ x y))", "'(1 2 3)", "\"a string\" 42 3.5"].each do |src|
      expected = Scheme::Reader.read_all(src, "t").map(&.write_string).join(" ")
      got = run(%[(tokens->forms (lex-tokens #{src.inspect} "t") "t")])
      got.write_string.should eq("(#{expected})")
    end
  end

  it "lex-tokens includes a trailing eof token" do
    run(%[(lex-tokens "x" "t")]).write_string.should eq(%[((symbol "x" 1 1) (eof "" 1 2))])
  end

  it "tokens->forms rejects a malformed token" do
    expect_raises(Scheme::SchemeRuntimeError, /malformed token/) do
      run(%[(tokens->forms (list (list 'symbol "x")) "t")])
    end
  end

  it "tokens->forms rejects an unknown token kind" do
    expect_raises(Scheme::SchemeRuntimeError, /unknown token kind/) do
      run(%[(tokens->forms (list (list 'bogus "x" 1 1)) "t")])
    end
  end
end
