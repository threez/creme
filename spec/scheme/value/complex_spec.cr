require "../../spec_helper"

describe Creme::SchemeComplex do
  it "make collapses to the bare real component when imag is exactly zero (exact)" do
    result = Creme::SchemeComplex.make(Creme::SchemeInt.new(3_i64), Creme::SchemeInt.new(0_i64))
    result.should be_a(Creme::SchemeInt)
  end

  it "make stays complex when imag is an inexact zero (0.0)" do
    result = Creme::SchemeComplex.make(Creme::SchemeInt.new(3_i64), Creme::SchemeFloat.new(0.0))
    result.should be_a(Creme::SchemeComplex)
  end

  it "displays as real+imagi" do
    Creme::SchemeComplex.make(Creme::SchemeInt.new(3_i64), Creme::SchemeInt.new(4_i64)).write_string.should eq("3+4i")
  end

  it "displays a negative imaginary part without a doubled sign" do
    Creme::SchemeComplex.make(Creme::SchemeInt.new(3_i64), Creme::SchemeInt.new(-4_i64)).write_string.should eq("3-4i")
  end

  it "wrap always constructs a genuine SchemeComplex, bypassing the collapse" do
    Creme::SchemeComplex.wrap(Creme::SchemeInt.new(3_i64), Creme::SchemeInt.new(0_i64)).should be_a(Creme::SchemeComplex)
  end
end
