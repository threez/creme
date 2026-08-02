require "../../spec_helper"

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "R7RS §6.2.1 Numerical types" do
  it "number?/real?/rational?/integer? classify the numeric tower correctly for exact integers" do
    w("(list (number? 3) (real? 3) (rational? 3) (integer? 3))").should eq("(#t #t #t #t)")
  end

  it "complex? is only available via (scheme complex), not the base library" do
    expect_raises(Creme::SchemeRuntimeError, /unbound variable: complex\?/) do
      run("(complex? 3)")
    end
    w("(import (scheme complex)) (complex? 3)").should eq("#t")
  end

  it "real?/rational?/integer? distinguish a non-integral rational and a non-rational real" do
    w("(list (rational? 3.5) (rational? (/ 6 10)) (integer? 3.0))").should eq("(#t #t #t)")
  end
end

describe "R7RS §6.2.2 Exactness" do
  it "exact?/inexact? partition every number into exactly one of the two categories" do
    w("(list (exact? 3.0) (inexact? 3.0) (exact? 3) (inexact? 3))").should eq("(#f #t #t #f)")
  end

  it "exact-integer? is #t only for numbers that are both exact and an integer" do
    w("(list (exact-integer? 32) (exact-integer? 32.0))").should eq("(#t #f)")
  end
end

describe "R7RS §6.2.3 Implementation restrictions" do
  it "arithmetic on exact integers whose mathematical result is representable stays exact" do
    w("(exact? (+ 2 3))").should eq("#t")
    w("(exact? (* 2 3))").should eq("#t")
  end

  it "division of two exact integers with a nonzero exact divisor produces an exact rational, not a float" do
    w("(/ 1 3)").should eq("1/3")
    w("(exact? (/ 1 3))").should eq("#t")
  end
end

describe "R7RS §6.2.4 Implementation extensions (infinities, NaN, negative zero)" do
  it "+inf.0/-inf.0/+nan.0 are recognized as reader literal syntax for the inexact special values" do
    w("(list +inf.0 -inf.0 +nan.0 -nan.0)").should eq("(+inf.0 -inf.0 +nan.0 +nan.0)")
  end

  it "the inf/nan literals behave correctly under the inexact-number predicates" do
    w("(import (scheme inexact)) (list (infinite? +inf.0) (nan? +nan.0) (finite? 3))").should eq("(#t #t #t)")
  end
end

describe "R7RS §6.2.5 Syntax of numerical constants" do
  it "a number with no radix prefix is read in decimal" do
    w("100").should eq("100")
  end

  it "radix prefixes #b/#o/#x/#d select binary/octal/hexadecimal/decimal" do
    w("(list #b101 #o17 #x1A #d100)").should eq("(5 15 26 100)")
  end

  it "exactness prefixes #e/#i force a literal to be read as exact/inexact" do
    w("(list #e3.0 #i3)").should eq("(3 3.0)")
  end

  it "radix and exactness prefixes combine, in either order" do
    w("(list #e#x1A #x#e1A)").should eq("(26 26)")
  end

  it "rational literal syntax (e.g. 1/3 typed directly in source) reads as an exact rational" do
    w("7/2").should eq("7/2")
    w("(exact? 1/3)").should eq("#t")
  end

  it "a rational literal auto-reduces to lowest terms, collapsing to a plain integer when the ratio is whole" do
    w("4/6").should eq("2/3")
    w("6/3").should eq("2")
  end
end

describe "R7RS §6.2.6 Numerical operations" do
  it "+ and * return the sum/product of their arguments, with the identity for zero arguments" do
    w("(list (+ 3 4) (+ 3) (+) (* 4) (*))").should eq("(7 3 0 4 1)")
  end

  it "- and / with one argument return the additive/multiplicative inverse" do
    w("(list (- 3) (/ 3))").should eq("(-3 1/3)")
  end

  it "- and / with two or more arguments associate to the left" do
    w("(list (- 3 4) (- 3 4 5) (/ 3 4 5))").should eq("(-1 -6 3/20)")
  end

  it "abs returns the absolute value" do
    w("(abs -7)").should eq("7")
  end

  it "floor/, truncate/ and their -quotient/-remainder halves implement the two division families" do
    w("(call-with-values (lambda () (floor/ 5 2)) list)").should eq("(2 1)")
    w("(call-with-values (lambda () (floor/ -5 2)) list)").should eq("(-3 1)")
    w("(call-with-values (lambda () (truncate/ 5 -2)) list)").should eq("(-2 1)")
    w("(list (floor-quotient 5 2) (floor-remainder 5 2))").should eq("(2 1)")
    w("(list (truncate-quotient -5 2) (truncate-remainder -5 2))").should eq("(-2 -1)")
  end

  it "quotient/remainder/modulo are backward-compatible synonyms for truncate-/floor- variants" do
    w("(list (quotient -5 2) (remainder -5 2) (modulo -5 2))").should eq("(-2 -1 1)")
  end

  it "gcd/lcm return the greatest common divisor / least common multiple, always non-negative" do
    w("(list (gcd 32 -36) (lcm 32 -36))").should eq("(4 288)")
    w("(list (gcd) (lcm))").should eq("(0 1)")
  end

  it "numerator/denominator return a fraction's parts in lowest terms, denominator of 0 is 1" do
    w("(list (numerator (/ 6 4)) (denominator (/ 6 4)) (denominator 0))").should eq("(3 2 1)")
  end

  it "floor/ceiling/truncate/round each return the appropriately-rounded integer" do
    w("(list (floor -4.3) (ceiling -4.3) (truncate -4.3) (round -4.3))").should eq("(-5.0 -4.0 -4.0 -4.0)")
  end

  it "round rounds to even when exactly halfway between two integers, staying exact for an exact rational argument" do
    w("(round 7/2)").should eq("4")
    w("(exact? (round 7/2))").should eq("#t")
  end

  it "floor/ceiling/truncate also accept exact rationals directly, staying exact" do
    w("(list (floor 7/2) (ceiling 7/2) (truncate 7/2) (floor -7/2) (ceiling -7/2))").should eq("(3 4 3 -4 -3)")
  end

  it "sqrt returns the principal square root, exact when the input is a perfect square (only available via (scheme inexact), not auto-imported with base)" do
    expect_raises(Creme::SchemeRuntimeError, /unbound variable: sqrt/) { run("(sqrt 9)") }
    w("(import (scheme inexact)) (sqrt 9)").should eq("3")
  end

  it "exact-integer-sqrt delivers two separate values (s r) under call-with-values" do
    w("(call-with-values (lambda () (exact-integer-sqrt 4)) list)").should eq("(2 0)")
    w("(call-with-values (lambda () (exact-integer-sqrt 5)) list)").should eq("(2 1)")
  end

  it "expt raises an exact base to an exact non-negative integer power, staying exact" do
    w("(expt 2 10)").should eq("1024")
  end

  it "expt with a negative exact integer exponent produces the exact reciprocal power" do
    w("(expt 2 -2)").should eq("1/4")
  end

  it "square is equivalent to (* z z)" do
    w("(list (square 42) (square 2.0))").should eq("(1764 4.0)")
  end
end

describe "R7RS §6.2.6 Numerical operations (transcendental, via (scheme inexact))" do
  it "exp/log/sin/cos/tan/asin/acos/atan are available after importing (scheme inexact)" do
    w("(import (scheme inexact)) (list (sin 0) (cos 0) (exp 0))").should eq("(0.0 1.0 1.0)")
  end

  it "log with a second argument computes the base-radix logarithm per R7RS's (log z1 z2)" do
    w("(import (scheme inexact)) (log 100 10)").should eq("2.0")
  end
end

describe "R7RS §6.2.7 Numerical input and output" do
  it "number->string / string->number round-trip through an explicit radix" do
    w("(list (number->string 100) (number->string 100 16) (string->number \"100\" 16))").should eq(%(("100" "64" 256)))
  end

  it "string->number returns #f on a string that is not a syntactically valid number" do
    w(%[(string->number "not-a-number")]).should eq("#f")
  end
end
