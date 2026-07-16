require "../../spec_helper"

describe Scheme::SchemeComplex do
  it "make collapses to the bare real component when imag is exactly zero (exact)" do
    result = Scheme::SchemeComplex.make(Scheme::SchemeInt.new(3_i64), Scheme::SchemeInt.new(0_i64))
    result.should be_a(Scheme::SchemeInt)
  end

  it "make stays complex when imag is an inexact zero (0.0)" do
    result = Scheme::SchemeComplex.make(Scheme::SchemeInt.new(3_i64), Scheme::SchemeFloat.new(0.0))
    result.should be_a(Scheme::SchemeComplex)
  end

  it "displays as real+imagi" do
    Scheme::SchemeComplex.make(Scheme::SchemeInt.new(3_i64), Scheme::SchemeInt.new(4_i64)).write_string.should eq("3+4i")
  end

  it "displays a negative imaginary part without a doubled sign" do
    Scheme::SchemeComplex.make(Scheme::SchemeInt.new(3_i64), Scheme::SchemeInt.new(-4_i64)).write_string.should eq("3-4i")
  end

  it "wrap always constructs a genuine SchemeComplex, bypassing the collapse" do
    Scheme::SchemeComplex.wrap(Scheme::SchemeInt.new(3_i64), Scheme::SchemeInt.new(0_i64)).should be_a(Scheme::SchemeComplex)
  end
end
