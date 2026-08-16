require "../../../spec_helper"

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme complex)) #{src}")
end

private def w(src : String) : String
  run(src).write_string
end

# Transcendental results (sin/cos/tan/exp/log/asin/acos/atan/... of a real OR
# a genuinely complex argument) are computed via the platform's own libm
# (Math.sin/cos/exp/... in Crystal's stdlib), so the last one or two bits of
# the mantissa can legitimately differ between platforms/architectures --
# observed Linux glibc vs. macOS's libm disagreeing in the last digit of a
# 17-significant-digit Float64#to_s across a rotating cast of specific cases
# each CI run (acos(1+1i), exp(1+1i), sin(1+2i), cos(1+2i), asin(0.5), ...).
# These are not creme bugs, just libm ULP-level differences in the
# underlying transcendental -- rather than fix them one at a time as a new
# one surfaces on a different platform, every transcendental assertion in
# this describe block uses w_complex_close. Parse the written form -- either
# a bare real "<real>" or complex "<real>[+-]<imag>i" -- back into Float64s
# and compare each within a small epsilon instead of asserting exact string
# equality.
private def w_complex_close(src : String, expected : String, epsilon = 1e-9)
  actual_re, actual_im = parse_complex_write_string(w(src))
  expected_re, expected_im = parse_complex_write_string(expected)
  actual_re.should be_close(expected_re, epsilon)
  actual_im.should be_close(expected_im, epsilon)
end

private def parse_complex_write_string(s : String) : {Float64, Float64}
  if m = s.match(/\A(-?[\d.]+(?:[eE][+-]?\d+)?)([+-][\d.]+(?:[eE][+-]?\d+)?)i\z/)
    {m[1].to_f64, m[2].to_f64}
  elsif m = s.match(/\A-?[\d.]+(?:[eE][+-]?\d+)?\z/)
    {m[0].to_f64, 0.0}
  else
    raise "not a real/complex write_string: #{s.inspect}"
  end
end

describe "(scheme complex)" do
  it "must be explicitly imported (not auto-imported like base)" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    expect_raises(Creme::SchemeRuntimeError, /unbound variable: make-rectangular/) do
      Creme.run_source(interp, "(make-rectangular 1 2)")
    end
  end

  describe "make-rectangular / real-part / imag-part" do
    it "constructs from real/imaginary parts" do
      w("(make-rectangular 3 4)").should eq("3+4i")
    end

    it "collapses to a bare real when the imaginary part is exactly 0" do
      w("(make-rectangular 3 0)").should eq("3")
    end

    it "stays complex when the imaginary part is an inexact 0.0" do
      w("(make-rectangular 3 0.0)").should eq("3+0.0i")
    end

    it "real-part/imag-part on a genuine complex value" do
      w("(real-part (make-rectangular 3 4))").should eq("3")
      w("(imag-part (make-rectangular 3 4))").should eq("4")
    end

    it "real-part/imag-part on a plain real number" do
      w("(real-part 5)").should eq("5")
      w("(imag-part 5)").should eq("0")
    end
  end

  describe "make-polar" do
    it "round-trips through real-part/imag-part" do
      interp = Creme::Interpreter.new(library_search_path: ["./modules"])
      result = Creme.run_source(interp, "(import (scheme complex)) (define p (make-polar 5 0)) (list (real-part p) (imag-part p))")
      result.write_string.should eq("(5.0 0.0)")
    end
  end

  describe "magnitude / angle" do
    it "magnitude of a complex value is its Euclidean norm, staying exact for a perfect-square sum" do
      w("(magnitude (make-rectangular 3 4))").should eq("5")
    end

    it "magnitude falls back to inexact once the sum of squares isn't a perfect-square integer" do
      w("(magnitude (make-rectangular 1 1))").should eq("1.4142135623730951")
      w("(magnitude (make-rectangular 3.0 4))").should eq("5.0")
    end

    it "magnitude of a real value falls back to abs" do
      w("(magnitude 5)").should eq("5")
      w("(magnitude -5)").should eq("5")
    end

    it "angle of a positive real is 0" do
      w("(angle 5)").should eq("0.0")
    end

    it "angle of a negative real is pi" do
      run("(angle -5)").as(Creme::SchemeFloat).value.should be_close(Math::PI, 1e-9)
    end
  end

  describe "complex?" do
    it "is true for any number, real or complex" do
      w("(complex? (make-rectangular 1 2))").should eq("#t")
      w("(complex? 5)").should eq("#t")
      w("(complex? 5.0)").should eq("#t")
      w("(complex? (/ 1 3))").should eq("#t")
    end
  end

  describe "arithmetic promotion" do
    it "adds two complex numbers component-wise" do
      w("(+ (make-rectangular 1 2) (make-rectangular 3 4))").should eq("4+6i")
    end

    it "subtracts two complex numbers component-wise" do
      w("(- (make-rectangular 5 5) (make-rectangular 1 1))").should eq("4+4i")
    end

    it "multiplies two complex numbers per the complex multiplication rule" do
      w("(* (make-rectangular 1 2) (make-rectangular 3 4))").should eq("-5+10i")
    end

    it "divides two complex numbers, staying exact when both operands are exact" do
      w("(/ (make-rectangular 1 2) (make-rectangular 1 0))").should eq("1+2i")
      w("(/ (make-rectangular 1 2) (make-rectangular 3 4))").should eq("11/25+2/25i")
    end

    it "division falls back to inexact once either operand has an inexact component" do
      w("(/ (make-rectangular 1.0 2) (make-rectangular 1 0))").should eq("1.0+2.0i")
    end

    it "division by a genuine complex zero raises, matching real division by zero" do
      expect_raises(Creme::SchemeRuntimeError, /division by zero/) do
        run("(/ (make-rectangular 1 2) (make-rectangular 0 0))")
      end
    end

    it "promotes a plain real operand to complex for mixed arithmetic" do
      w("(+ 1 (make-rectangular 0 1))").should eq("1+1i")
      w("(* 2 (make-rectangular 3 4))").should eq("6+8i")
    end

    it "a mixed-arithmetic result that lands on the real axis collapses to a real value" do
      w("(+ (make-rectangular 1 2) (make-rectangular 2 -2))").should eq("3")
    end
  end

  describe "sqrt of a negative real" do
    it "returns a complex result instead of raising or NaN" do
      w("(import (scheme inexact)) (sqrt -4)").should eq("0.0+2.0i")
      w("(import (scheme inexact)) (sqrt -1)").should eq("0.0+1.0i")
    end

    it "sqrt of a non-negative real is unaffected" do
      w("(import (scheme inexact)) (sqrt 4)").should eq("2")
      w("(import (scheme inexact)) (sqrt 4.0)").should eq("2.0")
    end
  end

  describe "complex-aware transcendentals" do
    it "sin/cos/tan/exp accept a genuine complex argument" do
      w_complex_close("(import (creme math)) (sin 1+2i)", "3.165778513216168+1.9596010414216063i")
      w_complex_close("(import (creme math)) (cos 1+2i)", "2.0327230070196656-3.0518977991518i")
      w_complex_close("(import (creme math)) (tan 1+2i)", "0.0338128260798966+1.0147936161466335i")
      w_complex_close("(import (creme math)) (exp 1+1i)", "1.4686939399158854+2.2873552871788427i")
    end

    it "sqrt of a genuinely complex argument" do
      w("(import (scheme inexact)) (sqrt -1+0.0i)").should eq("0.0+1.0i")
    end

    it "log of a genuinely complex argument, and of a negative real (domain extension)" do
      w_complex_close("(import (creme math)) (log 1+1i)", "0.3465735902799727+0.7853981633974483i")
      w_complex_close("(import (creme math)) (log -4)", "1.3862943611198906+3.141592653589793i")
      w("(import (creme math)) (log 0)").should eq("-inf.0")
    end

    it "asin/acos of an out-of-range real argument, and of a genuinely complex argument" do
      w_complex_close("(import (creme math)) (asin 2)", "1.5707963267948966-1.3169578969248166i")
      w_complex_close("(import (creme math)) (acos 2)", "0.0+1.3169578969248164i")
      w_complex_close("(import (creme math)) (asin 1+1i)", "0.6662394324925153+1.0612750619050355i")
      w_complex_close("(import (creme math)) (acos 1+1i)", "0.9045568943023814-1.0612750619050357i")
      w_complex_close("(import (creme math)) (asin 0.5)", "0.5235987755982989")
    end

    it "atan of a genuinely complex argument, real atan unaffected" do
      w_complex_close("(import (creme math)) (atan 1+1i)", "1.0172219678978514+0.4023594781085251i")
      w_complex_close("(import (creme math)) (atan 1)", "0.7853981633974483")
    end

    it "expt: negative real base with a non-integer exponent goes complex instead of NaN" do
      w("(import (creme math)) (expt -8 1/3)").should eq("1.0+1.732050807568877i")
    end

    it "expt: negative real base with an integer-valued exponent still stays real" do
      w("(import (creme math)) (expt -8.0 2.0)").should eq("64.0")
      w("(import (creme math)) (expt -8 3)").should eq("-512")
    end

    it "expt: a genuinely complex base or exponent" do
      w("(import (creme math)) (real-part (expt 1+1i 2))").should eq("1.2246467991473532e-16")
      w("(import (creme math)) (imag-part (expt 1+1i 2))").should eq("2.0")
    end
  end
end
