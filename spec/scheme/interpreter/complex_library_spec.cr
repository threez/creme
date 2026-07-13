require "../../spec_helper"

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, "(import (scheme complex)) #{src}")
end

private def w(src : String) : String
  run(src).write_string
end

describe "(scheme complex)" do
  it "must be explicitly imported (not auto-imported like base)" do
    interp = Scheme::Interpreter.new
    expect_raises(Scheme::SchemeRuntimeError, /unbound variable: make-rectangular/) do
      Scheme.run_source(interp, "(make-rectangular 1 2)")
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
      interp = Scheme::Interpreter.new
      result = Scheme.run_source(interp, "(import (scheme complex)) (define p (make-polar 5 0)) (list (real-part p) (imag-part p))")
      result.write_string.should eq("(5.0 0.0)")
    end
  end

  describe "magnitude / angle" do
    it "magnitude of a complex value is its Euclidean norm" do
      w("(magnitude (make-rectangular 3 4))").should eq("5.0")
    end

    it "magnitude of a real value falls back to abs" do
      w("(magnitude 5)").should eq("5")
      w("(magnitude -5)").should eq("5")
    end

    it "angle of a positive real is 0" do
      w("(angle 5)").should eq("0.0")
    end

    it "angle of a negative real is pi" do
      run("(angle -5)").as(Scheme::SchemeFloat).value.should be_close(Math::PI, 1e-9)
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

    it "divides two complex numbers" do
      w("(/ (make-rectangular 1 2) (make-rectangular 1 0))").should eq("1.0+2.0i")
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
end
