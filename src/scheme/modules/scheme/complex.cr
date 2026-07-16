# ===========================================================================
# (scheme complex)
# ===========================================================================
#
# Arithmetic promotion: num_add/num_sub/num_mul/divide
# (src/scheme/eval/builtin_helpers.cr) check "is either operand complex?"
# FIRST and short-circuit to to_complex/complex_add/complex_sub/complex_mul/
# complex_div (also in builtin_helpers.cr) if so, promoting the non-complex
# side to a zero-imaginary complex value — num_binop3's existing 3-way
# int/rational/float dispatch is untouched for the (overwhelmingly common)
# non-complex case, so this doesn't add a rank to that dispatcher or change
# its signature at all.

module Scheme::Builtins::Complex
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("complex?", min: 1, max: 1)]
  def complex_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(number?(args[0]))
  end

  @[Scheme::SchemeFn("make-rectangular", min: 2, max: 2)]
  def make_rectangular(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeComplex.make(real_component_arg(args[0], "make-rectangular"), real_component_arg(args[1], "make-rectangular"))
  end

  @[Scheme::SchemeFn("make-polar", min: 2, max: 2)]
  def make_polar(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    mag = Scheme.as_f64(args[0], "make-polar")
    ang = Scheme.as_f64(args[1], "make-polar")
    SchemeComplex.make(SchemeFloat.new(mag * Math.cos(ang)), SchemeFloat.new(mag * Math.sin(ang)))
  end

  @[Scheme::SchemeFn("real-part", min: 1, max: 1)]
  def real_part(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    v.is_a?(SchemeComplex) ? v.real.as(SchemeValue) : real_component_arg(v, "real-part").as(SchemeValue)
  end

  @[Scheme::SchemeFn("imag-part", min: 1, max: 1)]
  def imag_part(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    v.is_a?(SchemeComplex) ? v.imag.as(SchemeValue) : SchemeInt.new(0_i64).as(SchemeValue)
  end

  @[Scheme::SchemeFn("magnitude", min: 1, max: 1)]
  def magnitude(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    if v.is_a?(SchemeComplex)
      re, im = Scheme.as_f64(v.real, "magnitude"), Scheme.as_f64(v.imag, "magnitude")
      SchemeFloat.new(Math.sqrt(re*re + im*im)).as(SchemeValue)
    else
      interp.apply(interp.base_env.get("abs"), [v] of SchemeValue).as(SchemeValue)
    end
  end

  @[Scheme::SchemeFn("angle", min: 1, max: 1)]
  def angle(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    if v.is_a?(SchemeComplex)
      SchemeFloat.new(Math.atan2(Scheme.as_f64(v.imag, "angle"), Scheme.as_f64(v.real, "angle"))).as(SchemeValue)
    else
      f = Scheme.as_f64(real_component_arg(v, "angle"), "angle")
      SchemeFloat.new(f < 0 ? Math::PI : 0.0).as(SchemeValue)
    end
  end
end

module Scheme
  class Interpreter
    register_library ["scheme", "complex"], Scheme::Builtins::Complex
  end
end
