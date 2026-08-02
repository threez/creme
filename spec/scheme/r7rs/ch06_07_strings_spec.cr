require "../../spec_helper"

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "R7RS §6.7 Strings" do
  it "string? is #t for string objects" do
    w(%[(string? "abc")]).should eq("#t")
    w("(string? 'abc)").should eq("#f")
  end

  it "make-string returns a newly allocated string of length k, optionally filled with char" do
    w("(make-string 3 #\\a)").should eq(%("aaa"))
  end

  it "string returns a newly allocated string composed of its char arguments, analogous to list" do
    w("(string #\\a #\\b #\\c)").should eq(%("abc"))
    w("(string)").should eq(%(""))
  end

  it "string-length returns the number of characters in the string" do
    w(%[(string-length "abc")]).should eq("3")
  end

  it "string-ref returns the character at a zero-origin index" do
    w(%[(string-ref "abc" 1)]).should eq("#\\b")
  end

  it "string-set! stores char in element k of string" do
    w("(define s (make-string 3 #\\*)) (string-set! s 0 #\\?) s").should eq(%("?**"))
  end

  it "string=?/string-ci=? compare strings for equality (case-sensitive/insensitive)" do
    w(%[(string=? "abc" "abc" "abc")]).should eq("#t")
    w(%[(import (scheme char)) (string-ci=? "AbC" "abc")]).should eq("#t")
  end

  it "string<?/string>?/etc. compare strings lexicographically" do
    w(%[(string<? "a" "b")]).should eq("#t")
  end

  it "substring returns a newly allocated string copy of the given range" do
    w(%[(substring "hello world" 0 5)]).should eq(%("hello"))
  end

  it "string-append returns a newly allocated concatenation of its string arguments" do
    w(%[(string-append "foo" "bar")]).should eq(%("foobar"))
  end

  it "string->list/list->string convert between a string and a list of its characters, preserving order" do
    w(%[(string->list "abc")]).should eq("(#\\a #\\b #\\c)")
    w("(list->string (list #\\a #\\b #\\c))").should eq(%("abc"))
  end

  it "string-copy returns a newly allocated copy of the given range, defaulting to the whole string" do
    w(%[(string-copy "abcde" 1 4)]).should eq(%("bcd"))
  end

  it "string-copy! copies a range of characters from one string into another at a given offset" do
    w(%[(define a (string-copy "abcde")) (string-copy! a 1 "xyz" 0 2) a]).should eq(%("axyde"))
  end

  it "string-fill! stores fill in the elements of a string between start and end" do
    w("(define s (make-string 3)) (string-fill! s #\\a) s").should eq(%("aaa"))
  end

  it "string-map applies a procedure element-wise across one or more strings, returning a new string" do
    w(%[(import (scheme char)) (string-map char-upcase "abc")]).should eq(%("ABC"))
  end

  it "string-for-each calls a procedure for its side effects over each character in order" do
    w(<<-SCM).should eq("(101 100 99 98 97)")
      (define v '())
      (string-for-each (lambda (c) (set! v (cons (char->integer c) v))) "abcde")
      v
    SCM
  end

  it "string->vector/vector->string convert between a string and a vector of its characters" do
    w(%[(string->vector "ABC")]).should eq("#(#\\A #\\B #\\C)")
    w("(vector->string (vector #\\1 #\\2 #\\3))").should eq(%("123"))
  end

  describe "R7RS §6.7 Strings (via (scheme char))" do
    it "string-upcase/string-downcase/string-foldcase apply Unicode case mappings" do
      w(%[(import (scheme char)) (string-upcase "hi")]).should eq(%("HI"))
      w(%[(import (scheme char)) (string-downcase "HI")]).should eq(%("hi"))
      w(%[(import (scheme char)) (string-foldcase "HeLLo")]).should eq(%("hello"))
    end
  end
end
