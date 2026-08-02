require "../../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (creme string)) #{src}").write_string
end

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (creme string)) #{src}")
end

describe "string module" do
  it "upcases, downcases, trims, reverses" do
    w(%((string-upcase "abc"))).should eq(%("ABC"))
    w(%((string-downcase "ABC"))).should eq(%("abc"))
    w(%((string-trim "  hi  "))).should eq(%("hi"))
    w(%((string-reverse "abc"))).should eq(%("cba"))
  end

  it "splits and joins" do
    w(%((string-split "a,b,c" ","))).should eq(%(("a" "b" "c")))
    w(%((string-join (list "a" "b" "c") "-"))).should eq(%("a-b-c"))
  end

  it "checks contains?/prefix?/suffix?/index-of" do
    w(%((string-contains? "hello" "ell"))).should eq("#t")
    w(%((string-prefix? "hello" "he"))).should eq("#t")
    w(%((string-suffix? "hello" "lo"))).should eq("#t")
    w(%((string-index-of "hello" "l"))).should eq("2")
    w(%((string-index-of "hello" "z"))).should eq("#f")
  end

  it "explodes into chars via base string->list, repeats, and pads" do
    w(%((string->list "ab"))).should eq("(#\\a #\\b)")
    w(%((string-repeat "ab" 3))).should eq(%("ababab"))
    w(%((string-pad "7" 3 "0"))).should eq(%("007"))
    w(%((string-pad-right "7" 3 "0"))).should eq(%("700"))
  end

  it "raises on non-string arguments" do
    expect_raises(Creme::SchemeRuntimeError, /string-upcase: expected string/) do
      run("(string-upcase 5)")
    end
  end

  it "translates every occurrence of each aliased char in one pass" do
    w(%q((string-translate "a&b<c>d" (list (cons #\& "&amp;") (cons #\< "&lt;") (cons #\> "&gt;")))))
      .should eq(%("a&amp;b&lt;c&gt;d"))
  end

  it "leaves a string with no matching characters unchanged" do
    w(%q((string-translate "hello" (list (cons #\& "&amp;"))))).should eq(%("hello"))
  end

  it "returns the empty string for empty input" do
    w(%q((string-translate "" (list (cons #\& "&amp;"))))).should eq(%(""))
  end

  it "raises on a malformed pairs alist" do
    expect_raises(Creme::SchemeRuntimeError, /string-translate: expected an alist/) do
      run(%q((string-translate "x" (list (cons "&" "&amp;")))))
    end
  end
end
