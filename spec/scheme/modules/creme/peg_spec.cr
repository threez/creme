require "../../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (scheme base) (scheme write) (scheme char) (scheme cxr) (creme peg)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (scheme base) (scheme char) (creme peg)) #{src}")
end

describe "(creme peg)" do
  it "peg-lit matches a literal (as (value . new-pos)) and fails (#f) otherwise" do
    w(%[((peg-lit "ab") "abc" 0)]).should eq(%(("ab" . 2)))
    w(%[((peg-lit "ab") "xy" 0)]).should eq("#f")
  end

  it "peg-char-pred matches one char satisfying a predicate" do
    w(%[((peg-char-pred char-numeric?) "5" 0)]).should eq(%[(#\\5 . 1)])
  end

  it "peg-seq collects each sub-parser's value, in order" do
    w(%[(peg-run (peg-seq (peg-lit "a") (peg-lit "b")) "ab")]).should eq(%(("a" "b")))
  end

  it "peg-seq fails atomically -- a later failure fails the whole match" do
    w(%[((peg-seq (peg-lit "a") (peg-lit "b")) "ac" 0)]).should eq("#f")
  end

  it "peg-alt tries alternatives in order from the same starting position" do
    w(%[(peg-run (peg-alt (peg-lit "a") (peg-lit "b")) "b")]).should eq(%("b"))
  end

  it "peg-many matches zero or more, always succeeding" do
    w(%[(peg-run (peg-map (peg-many (peg-lit "a")) length) "aaa")]).should eq("3")
    w(%[(peg-run (peg-map (peg-many (peg-lit "a")) length) "")]).should eq("0")
  end

  it "peg-many1 requires at least one match" do
    w(%[((peg-many1 (peg-lit "a")) "" 0)]).should eq("#f")
  end

  it "peg-opt never fails, yielding #f (without consuming) when its parser doesn't match" do
    w(%[((peg-opt (peg-lit "a")) "b" 0)]).should eq("(#f . 0)")
  end

  it "peg-not is a zero-width negative lookahead" do
    w(%[(peg-run (peg-seq (peg-not (peg-lit "b")) (peg-any)) "a")]).should eq(%[(#f #\\a)])
  end

  it "peg-while accumulates a run of matching chars into a string" do
    w(%[(peg-run (peg-while char-alphabetic?) "abc")]).should eq(%("abc"))
  end

  it "peg-until-lit stops at (not consuming) the target literal" do
    w(%[(peg-run (peg-seq (peg-until-lit "STOP") (peg-lit "STOP")) "helloSTOP")])
      .should eq(%(("hello" "STOP")))
  end

  it "peg-lazy supports a self-referential/recursive grammar" do
    w(<<-SCHEME).should eq(%("(((x)))"))
      (letrec ((expr (peg-alt (peg-map (peg-seq (peg-lit "(") (peg-lazy (lambda () expr)) (peg-lit ")"))
                                        (lambda (parts) (string-append (car parts) (cadr parts) (caddr parts))))
                              (peg-lit "x"))))
        (peg-run expr "(((x)))"))
      SCHEME
  end

  it "peg-must raises a specific error instead of backtracking on failure" do
    expect_raises(Scheme::SchemeRuntimeError, /wanted a/) do
      run(%[(peg-run (peg-must (peg-lit "a") "wanted a") "b")])
    end
  end

  it "peg-run raises if the parser doesn't consume the whole input" do
    expect_raises(Scheme::SchemeRuntimeError, /did not consume all input/) do
      run(%[(peg-run (peg-lit "a") "ab")])
    end
  end

  it "peg-char-in/peg-char-not-in match membership in a list of chars" do
    w(%[(peg-run (peg-char-in (list #\\a #\\b)) "b")]).should eq(%[#\\b])
    w(%[((peg-char-in (list #\\a #\\b)) "c" 0)]).should eq("#f")
    w(%[(peg-run (peg-many (peg-char-not-in (list #\\{ #\\;))) "abc")]).should eq(%[(#\\a #\\b #\\c)])
  end

  it "peg-balanced-parens matches one balanced group, string-aware (parens inside the nested string don't affect the depth count)" do
    w(%q{((peg-balanced-parens) "(if a \"(\" b) rest" 0)}).should eq(%q{("(if a \"(\" b)" . 12)})
    w(%[((peg-balanced-parens) "no-parens" 0)]).should eq("#f")
  end

  it "peg-skip drops its value from the enclosing peg-seq's result entirely" do
    w(%[(peg-run (peg-seq (peg-skip (peg-lit "(")) (peg-lit "x") (peg-skip (peg-lit ")"))) "(x)")])
      .should eq(%(("x")))
  end

  it "peg-seq-map spreads peg-seq's (post-peg-skip) values as named arguments" do
    w(%[(peg-run (peg-seq-map (list (peg-skip (peg-lit "(")) (peg-lit "x") (peg-skip (peg-lit ",")) (peg-lit "y")
                                      (peg-skip (peg-lit ")")))
                                (lambda (a b) (cons a b)))
                  "(x,y)")])
      .should eq(%(("x" . "y")))
  end
end
