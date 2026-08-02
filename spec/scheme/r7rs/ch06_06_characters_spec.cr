require "../../spec_helper"

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "R7RS §6.6 Characters" do
  it "char? is #t for character objects" do
    w("(char? #\\a)").should eq("#t")
    w("(char? 97)").should eq("#f")
  end

  it "char=?/char<?/etc. compare characters via their integer scalar values" do
    w("(char=? #\\A #\\A)").should eq("#t")
    w("(char<? #\\a #\\b)").should eq("#t")
  end

  it "char->integer/integer->char convert between a character and its Unicode scalar value" do
    w("(char->integer #\\a)").should eq("97")
    w("(integer->char 97)").should eq("#\\a")
  end

  it "the named characters newline/return/space/tab are supported" do
    w("(char->integer #\\newline)").should eq("10")
    w("(char->integer #\\return)").should eq("13")
    w("(char->integer #\\space)").should eq("32")
    w("(char->integer #\\tab)").should eq("9")
  end

  it "the remaining 5 required named characters alarm/backspace/delete/escape/null are also supported" do
    w("(list (char->integer #\\alarm) (char->integer #\\backspace) (char->integer #\\delete) (char->integer #\\escape) (char->integer #\\null))").should eq("(7 8 127 27 0)")
  end

  it "#\\x<hex-scalar-value> reads a character by its Unicode hex scalar value" do
    w("(char->integer #\\x03B1)").should eq("945")
    w("(char->integer #\\x41)").should eq("65")
  end

  it "bare #\\x with no following hex digit is the ordinary letter x" do
    w("(char->integer #\\x)").should eq("120")
  end

  it "ordinary printing characters like #\\a, #\\A, #\\( are self-evaluating literals" do
    w("(list #\\a #\\A #\\()").should eq("(#\\a #\\A #\\()")
  end

  describe "R7RS §6.6 Characters (via (scheme char))" do
    it "char-ci=?/char-upcase/char-downcase/char-foldcase are case-insensitive/case-converting" do
      w("(import (scheme char)) (list (char-ci=? #\\A #\\a) (char-upcase #\\a) (char-downcase #\\A) (char-foldcase #\\A))").should eq("(#t #\\A #\\a #\\a)")
    end

    it "char-alphabetic?/char-numeric?/char-whitespace?/char-upper-case?/char-lower-case? classify characters" do
      w("(import (scheme char)) (list (char-alphabetic? #\\a) (char-numeric? #\\3) (char-whitespace? #\\space) (char-upper-case? #\\A) (char-lower-case? #\\a))").should eq("(#t #t #t #t #t)")
    end

    it "digit-value returns a decimal digit character's numeric value, #f for non-digits" do
      w("(import (scheme char)) (digit-value #\\3)").should eq("3")
      w("(import (scheme char)) (digit-value #\\a)").should eq("#f")
    end
  end
end
