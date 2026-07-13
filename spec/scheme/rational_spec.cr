require "../spec_helper"

describe Scheme::SchemeRational do
  describe ".make" do
    it "reduces to lowest terms" do
      r = Scheme::SchemeRational.make(2_i64, 4_i64)
      r.should be_a(Scheme::SchemeRational)
      r.as(Scheme::SchemeRational).numerator.should eq(1_i64)
      r.as(Scheme::SchemeRational).denominator.should eq(2_i64)
    end

    it "collapses to SchemeInt when the ratio is a whole number" do
      r = Scheme::SchemeRational.make(6_i64, 3_i64)
      r.should be_a(Scheme::SchemeInt)
      r.as(Scheme::SchemeInt).value.should eq(2_i64)
    end

    it "collapses to SchemeInt(0) when the numerator is 0" do
      r = Scheme::SchemeRational.make(0_i64, 5_i64)
      r.should be_a(Scheme::SchemeInt)
      r.as(Scheme::SchemeInt).value.should eq(0_i64)
    end

    it "normalizes a negative denominator onto the numerator" do
      r = Scheme::SchemeRational.make(1_i64, -2_i64).as(Scheme::SchemeRational)
      r.numerator.should eq(-1_i64)
      r.denominator.should eq(2_i64)
    end

    it "keeps a negative numerator with a positive denominator as-is" do
      r = Scheme::SchemeRational.make(-1_i64, 2_i64).as(Scheme::SchemeRational)
      r.numerator.should eq(-1_i64)
      r.denominator.should eq(2_i64)
    end

    it "reduces when both numerator and denominator are negative" do
      r = Scheme::SchemeRational.make(-2_i64, -4_i64)
      r.should be_a(Scheme::SchemeRational)
      r.as(Scheme::SchemeRational).numerator.should eq(1_i64)
      r.as(Scheme::SchemeRational).denominator.should eq(2_i64)
    end

    it "raises on a zero denominator" do
      expect_raises(Scheme::SchemeRuntimeError, /division by zero/) do
        Scheme::SchemeRational.make(1_i64, 0_i64)
      end
    end
  end

  describe "#to_display" do
    it "displays as numerator/denominator" do
      Scheme::SchemeRational.make(1_i64, 3_i64).display_string.should eq("1/3")
    end

    it "displays a negative rational with the sign on the numerator" do
      Scheme::SchemeRational.make(-1_i64, 3_i64).display_string.should eq("-1/3")
    end

    it "writes the same as it displays" do
      Scheme::SchemeRational.make(1_i64, 3_i64).write_string.should eq("1/3")
    end
  end
end

describe "Scheme.int_gcd" do
  it "computes the greatest common divisor" do
    Scheme.int_gcd(12_i64, 18_i64).should eq(6_i64)
  end

  it "is always non-negative" do
    Scheme.int_gcd(-12_i64, 18_i64).should eq(6_i64)
    Scheme.int_gcd(12_i64, -18_i64).should eq(6_i64)
  end

  it "gcd of 0 and 0 is 0" do
    Scheme.int_gcd(0_i64, 0_i64).should eq(0_i64)
  end

  it "gcd of 0 and n is n" do
    Scheme.int_gcd(0_i64, 5_i64).should eq(5_i64)
  end
end

describe "Scheme.int_lcm" do
  it "computes the least common multiple" do
    Scheme.int_lcm(4_i64, 6_i64).should eq(12_i64)
  end

  it "lcm with 0 is 0" do
    Scheme.int_lcm(0_i64, 5_i64).should eq(0_i64)
  end
end
