require "../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (creme abbrev) (creme sort)) #{src}").write_string
end

describe "abbrev module" do
  it "maps unique abbreviations of two similar words" do
    w(<<-SCHEME).should eq(%(("ruby" "ruby" #f "rules" "rules")))
      (define table (abbrev '("ruby" "rules")))
      (list
       (abbrev-resolve table "rub")
       (abbrev-resolve table "ruby")
       (abbrev-resolve table "ru")
       (abbrev-resolve table "rul")
       (abbrev-resolve table "rules"))
      SCHEME
  end

  it "always includes every full word even if fully ambiguous" do
    w(<<-SCHEME).should eq("(#t #t)")
      (define table (abbrev '("a" "ab")))
      (list
       (equal? "a" (abbrev-resolve table "a"))
       (equal? "ab" (abbrev-resolve table "ab")))
      SCHEME
  end

  it "returns #f for a prefix not present at all" do
    w("(abbrev-resolve (abbrev '(\"cat\" \"dog\")) \"z\")").should eq("#f")
  end

  it "handles a single word: every prefix is unambiguous" do
    w("(list-sort string<? (map car (abbrev '(\"cat\"))))").should eq("(\"c\" \"ca\" \"cat\")")
  end
end
