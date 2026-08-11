require "../../spec_helper"

private def close(pair : {Float64, Float64}, expected : {Float64, Float64}, delta = 1e-9)
  pair[0].should be_close(expected[0], delta)
  pair[1].should be_close(expected[1], delta)
end

describe Creme::ComplexMath do
  it "exp(i*pi) is close to (-1, 0) — Euler's identity" do
    close(Creme::ComplexMath.exp(0.0, Math::PI), {-1.0, 0.0})
  end

  it "log is the inverse of exp" do
    re, im = Creme::ComplexMath.exp(0.3, 0.7)
    close(Creme::ComplexMath.log(re, im), {0.3, 0.7})
  end

  it "sqrt squared via mul gives back the original value" do
    sre, sim = Creme::ComplexMath.sqrt(-4.0, 0.0)
    close(Creme::ComplexMath.mul(sre, sim, sre, sim), {-4.0, 0.0})
  end

  it "sqrt of a negative real puts the root on the imaginary axis" do
    close(Creme::ComplexMath.sqrt(-4.0, 0.0), {0.0, 2.0})
  end

  it "sin^2 + cos^2 == 1 for a complex argument" do
    sr, si = Creme::ComplexMath.sin(1.0, 2.0)
    cr, ci = Creme::ComplexMath.cos(1.0, 2.0)
    s2 = Creme::ComplexMath.mul(sr, si, sr, si)
    c2 = Creme::ComplexMath.mul(cr, ci, cr, ci)
    close(Creme::ComplexMath.add(s2[0], s2[1], c2[0], c2[1]), {1.0, 0.0})
  end

  it "tan is sin/cos" do
    sr, si = Creme::ComplexMath.sin(1.0, 2.0)
    cr, ci = Creme::ComplexMath.cos(1.0, 2.0)
    close(Creme::ComplexMath.tan(1.0, 2.0), Creme::ComplexMath.div(sr, si, cr, ci))
  end

  it "asin/acos of an out-of-range real matches the known closed form" do
    close(Creme::ComplexMath.asin(2.0, 0.0), {Math::PI/2, -Math.log(2 + Math.sqrt(3.0))})
    close(Creme::ComplexMath.acos(2.0, 0.0), {0.0, Math.log(2 + Math.sqrt(3.0))})
  end

  it "atan(1) real-only case matches Math.atan" do
    close(Creme::ComplexMath.atan(1.0, 0.0), {Math.atan(1.0), 0.0})
  end

  it "pow matches exp(exponent * log(base))" do
    close(Creme::ComplexMath.pow(-8.0, 0.0, 1.0/3.0, 0.0), {1.0, Math.sqrt(3.0)})
  end

  it "pow of zero base is zero" do
    Creme::ComplexMath.pow(0.0, 0.0, 2.0, 0.0).should eq({0.0, 0.0})
  end
end
