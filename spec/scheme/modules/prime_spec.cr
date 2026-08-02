require "../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (creme prime)) #{src}").write_string
end

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (creme prime)) #{src}")
end

describe "prime module" do
  it "recognizes primes" do
    w("(map prime? '(2 3 4 5 6 7 8 9 10 11))").should eq("(#t #t #f #t #f #t #f #f #f #t)")
  end

  it "treats numbers below 2 as not prime" do
    w("(map prime? '(-3 0 1))").should eq("(#f #f #f)")
  end

  it "finds the next prime" do
    w("(next-prime 10)").should eq("11")
    w("(next-prime 2)").should eq("3")
    w("(next-prime 1)").should eq("2")
  end

  it "factors a composite number" do
    w("(prime-factors 360)").should eq("((2 . 3) (3 . 2) (5 . 1))")
  end

  it "factors a prime number as itself to the first power" do
    w("(prime-factors 17)").should eq("((17 . 1))")
  end

  it "returns no factors for 1" do
    w("(prime-factors 1)").should eq("()")
  end

  it "raises for n < 1" do
    expect_raises(Creme::SchemeError) { run("(prime-factors 0)") }
  end

  it "lists primes up to n via the sieve" do
    w("(primes-upto 20)").should eq("(2 3 5 7 11 13 17 19)")
  end

  it "returns no primes below 2" do
    w("(primes-upto 1)").should eq("()")
  end
end
