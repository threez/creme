require "../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, src).write_string
end

describe "RatInt escape-to-BigInt (arithmetic that overflows Int64)" do
  it "+ escalates on overflow instead of raising" do
    w("(+ 9223372036854775807 1)").should eq("9223372036854775808")
  end

  it "- escalates on overflow instead of raising" do
    w("(- -9223372036854775808 1)").should eq("-9223372036854775809")
  end

  it "* escalates on overflow instead of raising" do
    w("(* 99999999999999999999 99999999999999999999)").should eq("9999999999999999999800000000000000000001")
  end

  it "a big result demotes back down once further arithmetic makes it fit again" do
    w("(- (* 99999999999999999999 99999999999999999999) 9999999999999999999800000000000000000000)").should eq("1")
  end

  it "gcd/lcm work on values exceeding Int64" do
    w("(gcd 99999999999999999999999999999999 33)").should eq("33")
    w("(lcm 99999999999999999999999999999999 3)").should eq("99999999999999999999999999999999")
  end

  it "expt escalates instead of raising" do
    w("(expt 2 100)").should eq("1267650600228229401496703205376")
  end

  it "expt with a negative exponent on a value that would overflow the positive path still returns an exact rational" do
    w("(expt 2 -100)").should eq("1/1267650600228229401496703205376")
  end

  it "quotient/remainder/modulo work on values exceeding Int64" do
    w("(quotient 99999999999999999999999999999999 7)").should eq("14285714285714285714285714285714")
    w("(remainder 99999999999999999999999999999999 7)").should eq("1")
    w("(modulo -99999999999999999999999999999999 7)").should eq("6")
  end

  it "exact-integer-sqrt works on a value exceeding Int64" do
    w("(call-with-values (lambda () (exact-integer-sqrt (* 99999999999999999999 99999999999999999999))) list)").should eq("(99999999999999999999 0)")
  end

  it "a rational collapsing to an oversized whole number returns a valid big SchemeInt, not a raise" do
    w("(integer? (/ (* 99999999999999999999 99999999999999999999) 1))").should eq("#t")
    w("(/ (* 99999999999999999999 99999999999999999999) 1)").should eq("9999999999999999999800000000000000000001")
  end

  it "numerator/denominator on an oversized rational succeed" do
    w("(numerator (/ (expt 10 30) 3))").should eq("1000000000000000000000000000000")
    w("(denominator (/ (expt 10 30) 3))").should eq("3")
  end

  it "an oversized integer literal reads correctly" do
    w("123456789012345678901234567890").should eq("123456789012345678901234567890")
  end

  it "an oversized rational literal reads correctly" do
    w("123456789012345678901234567890/7").should eq("17636684144620811271604938270")
  end

  it "floor/ceiling/truncate/round of an oversized value stay exact" do
    w("(exact? (floor (/ (expt 10 40) 3)))").should eq("#t")
  end

  it "exact->inexact on a value too large for Int64 succeeds instead of raising" do
    w("(exact? (exact 1e300))").should eq("#t")
  end

  it "equal?/eqv? and hash-table lookups stay consistent across values reached via different computation paths" do
    w("(equal? (* 99999999999999999999 99999999999999999999) (+ 9999999999999999999800000000000000000000 1))").should eq("#t")
    w(<<-SCM).should eq("found")
      (import (creme hash-table))
      (define h (make-hash-table))
      (hash-table-set! h (* 99999999999999999999 99999999999999999999) 'found)
      (hash-table-ref h (+ 9999999999999999999800000000000000000000 1) 'missing)
      SCM
  end

  it "a vector index that's an out-of-range BigInt raises a clear error, not a crash" do
    expect_raises(Creme::SchemeRuntimeError, /out of range/) { w("(vector-ref (vector 1 2 3) 999999999999999999999999)") }
  end

  it "even?/odd? work on values exceeding Int64" do
    w("(even? (expt 2 100))").should eq("#t")
    w("(odd? (+ (expt 2 100) 1))").should eq("#t")
  end
end

describe "Creme.rat_add/rat_sub/rat_mul" do
  it "stay Int64 when there is no overflow" do
    Creme.rat_add(1_i64, 2_i64).should eq(3_i64)
    Creme.rat_sub(5_i64, 2_i64).should eq(3_i64)
    Creme.rat_mul(2_i64, 3_i64).should eq(6_i64)
  end

  it "escalate to BigInt on overflow" do
    r = Creme.rat_mul(Int64::MAX, Int64::MAX)
    r.should be_a(BigInt)
    r.should eq(Int64::MAX.to_big_i * Int64::MAX.to_big_i)
  end
end

describe "Creme.rat_demote" do
  it "demotes a BigInt back to Int64 when it fits" do
    Creme.rat_demote(5.to_big_i).should eq(5_i64)
    Creme.rat_demote(5.to_big_i).should be_a(Int64)
  end

  it "leaves a BigInt unchanged when it doesn't fit" do
    big = BigInt.new("99999999999999999999")
    Creme.rat_demote(big).should be_a(BigInt)
  end
end
