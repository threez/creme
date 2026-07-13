require "../../spec_helper"

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "R7RS §6.5 Symbols" do
  it "symbol? is #t for symbols" do
    w("(symbol? 'foo)").should eq("#t")
    w("(symbol? (car '(a b)))").should eq("#t")
    w(%[(symbol? "bar")]).should eq("#f")
    w("(symbol? '())").should eq("#f")
    w("(symbol? #f)").should eq("#f")
  end

  it "symbol=? is #t if all arguments are symbols with the same name" do
    w("(symbol=? 'a 'a 'a)").should eq("#t")
    w("(symbol=? 'a 'b)").should eq("#f")
  end

  it "symbol->string returns the symbol's name as a string" do
    w("(symbol->string 'flying-fish)").should eq(%("flying-fish"))
    w("(symbol->string 'Martin)").should eq(%("Martin"))
  end

  it "string->symbol returns the symbol whose name is the given string, without interpreting escapes" do
    w(%[(string->symbol "mISSISSIppi")]).should eq("mISSISSIppi")
    w(%[(eqv? 'bitBlt (string->symbol "bitBlt"))]).should eq("#t")
  end

  it "symbol->string and string->symbol are inverses for round-tripping a symbol through a string" do
    w("(eqv? 'LollyPop (string->symbol (symbol->string 'LollyPop)))").should eq("#t")
  end

  it "string->symbol can create symbols whose names contain characters needing escapes when written" do
    w(%[(string=? "K. Harper, M.D." (symbol->string (string->symbol "K. Harper, M.D.")))]).should eq("#t")
  end

  it "a symbol read/written via write round-trips back to the identical symbol, using |...| vertical-bar escaping for names containing special characters" do
    w(<<-SCM).should eq(%("|two words|"))
      (define op (open-output-string))
      (write (string->symbol "two words") op)
      (get-output-string op)
    SCM
    w(<<-SCM).should eq("#t")
      (import (scheme read))
      (define s (string->symbol "two words"))
      (define p (open-output-string))
      (write s p)
      (eqv? s (read (open-input-string (get-output-string p))))
    SCM
  end
end
