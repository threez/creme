require "../../spec_helper"

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "R7RS §2.1 Identifiers" do
  it "accepts the extended identifier characters ! $ % & * + - . / : < = > ? @ ^ _ ~" do
    w("(define ->string 1) ->string").should eq("1")
    w("(define +soup+ 2) +soup+").should eq("2")
    w("(define list->vector 3) list->vector").should eq("3")
    w("(define the-word-recursion-has-many-meanings 4) the-word-recursion-has-many-meanings").should eq("4")
  end

  it "a delimited + or - by itself is an identifier (bound to the addition/subtraction procedure in the base library)" do
    w("+").should eq("#<builtin:+>")
  end

  it "|...| vertical-line identifiers can contain arbitrary characters, including whitespace" do
    w("(define |two words| 5) |two words|").should eq("5")
  end

  it "|H\\x65;llo| denotes the same identifier as Hello (hex-escape inside a |...| identifier)" do
    w("(eqv? 'Hello '|H\\x65;llo|)").should eq("#t")
    w("(define Hello 6) |H\\x65;llo|").should eq("6")
  end
end

describe "R7RS §2.2 Whitespace and comments" do
  it "; starts a line comment extending to end of line" do
    w("(+ 1 2) ; this is a comment\n").should eq("3")
  end

  it "#; is a datum comment, skipping exactly one following datum" do
    w("(+ 1 #;(this is ignored) 2)").should eq("3")
  end

  it "#| ... |# is a nestable block comment" do
    w("#| outer #| inner |# still outer |# (+ 1 2)").should eq("3")
  end

  pending "#!fold-case / #!no-fold-case directives are not implemented (reader raises 'unknown # syntax')"
end

describe "R7RS §2.3 Other notations" do
  it "#t and #true both denote the boolean true" do
    w("#t").should eq("#t")
    w("#true").should eq("#t")
  end

  it "#f and #false both denote the boolean false" do
    w("#f").should eq("#f")
    w("#false").should eq("#f")
  end

  it "parentheses group and notate lists; apostrophe indicates literal data" do
    w("'(+ 1 2)").should eq("(+ 1 2)")
  end
end

describe "R7RS §2.4 Datum labels" do
  it "#n=datum labels a datum, and #n# elsewhere in the same outermost datum refers back to it, preserving identity" do
    w("(import (scheme read)) (let ((x (read (open-input-string \"(#0=(a b c) #0#)\")))) (eq? (car x) (cadr x)))").should eq("#t")
  end

  it "supports genuinely circular structure, e.g. #0=(1 2 . #0#)" do
    w(<<-SCM).should eq("(1 2 #t)")
      (import (scheme read))
      (define x (read (open-input-string "#0=(1 2 . #0#)")))
      (list (car x) (car (cdr x)) (eq? x (cdr (cdr x))))
    SCM
  end

  it "a datum label's scope is only the outermost datum it appears in — reusing the same label number in a later top-level form is not an error" do
    w(<<-SCM).should eq("(a b)")
      (import (scheme read))
      (define p (open-input-string "#0=a #0=b"))
      (list (read p) (read p))
    SCM
  end
end
