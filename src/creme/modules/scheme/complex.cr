# ===========================================================================
# (scheme complex)
# ===========================================================================
#
# Arithmetic promotion: num_add/num_sub/num_mul/divide
# (src/creme/eval/builtin_helpers.cr) check "is either operand complex?"
# FIRST and short-circuit to to_complex/complex_add/complex_sub/complex_mul/
# complex_div (also in builtin_helpers.cr) if so, promoting the non-complex
# side to a zero-imaginary complex value — num_binop3's existing 3-way
# int/rational/float dispatch is untouched for the (overwhelmingly common)
# non-complex case, so this doesn't add a rank to that dispatcher or change
# its signature at all.

module Creme::R7RS::Complex
  extend self
  include Creme::BuiltinHelpers

  @[Creme::SchemeFn("complex?", min: 1, max: 1)]
  def complex_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(number?(args[0]))
  end

  @[Creme::SchemeFn("make-rectangular", min: 2, max: 2)]
  def make_rectangular(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeComplex.make(real_component_arg(args[0], "make-rectangular"), real_component_arg(args[1], "make-rectangular"))
  end

  @[Creme::SchemeFn("make-polar", min: 2, max: 2)]
  def make_polar(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    mag = Creme.as_f64(args[0], "make-polar")
    ang = Creme.as_f64(args[1], "make-polar")
    SchemeComplex.make(SchemeFloat.new(mag * Math.cos(ang)), SchemeFloat.new(mag * Math.sin(ang)))
  end

  @[Creme::SchemeFn("real-part", min: 1, max: 1)]
  def real_part(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    v.is_a?(SchemeComplex) ? v.real.as(SchemeValue) : real_component_arg(v, "real-part").as(SchemeValue)
  end

  @[Creme::SchemeFn("imag-part", min: 1, max: 1)]
  def imag_part(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    v.is_a?(SchemeComplex) ? v.imag.as(SchemeValue) : SchemeInt.new(0_i64).as(SchemeValue)
  end

  # magnitude is sqrt(re^2 + im^2) — stays exact when re^2 + im^2 is an
  # exact perfect-square integer (e.g. (magnitude (make-rectangular 3 4))
  # is exact 5, not 5.0), reusing the same exact-integer-square-root logic
  # (exact_integer_sqrt_pair) sqrt's own perfect-square fast path uses.
  # re^2 + im^2 can also be an exact non-integer rational (e.g. re/im are
  # themselves rationals) — sqrt of THAT stays inexact, same as sqrt's own
  # scope (no exact rational-radicand fast path either), not a regression.
  @[Creme::SchemeFn("magnitude", min: 1, max: 1)]
  def magnitude(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    if v.is_a?(SchemeComplex)
      sumsq = num_add(num_mul(v.real, v.real, "magnitude"), num_mul(v.imag, v.imag, "magnitude"), "magnitude")
      if (sumsq.is_a?(SchemeInt) || sumsq.is_a?(SchemeBigInt)) && sumsq.value >= 0
        root, rem = exact_integer_sqrt_pair(sumsq.value)
        return Creme.int_value(root).as(SchemeValue) if rem == 0
      end
      SchemeFloat.new(Math.sqrt(Creme.as_f64(sumsq, "magnitude"))).as(SchemeValue)
    else
      interp.apply(interp.base_env.get("abs"), [v] of SchemeValue).as(SchemeValue)
    end
  end

  @[Creme::SchemeFn("angle", min: 1, max: 1)]
  def angle(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    if v.is_a?(SchemeComplex)
      SchemeFloat.new(Math.atan2(Creme.as_f64(v.imag, "angle"), Creme.as_f64(v.real, "angle"))).as(SchemeValue)
    else
      f = Creme.as_f64(real_component_arg(v, "angle"), "angle")
      SchemeFloat.new(f < 0 ? Math::PI : 0.0).as(SchemeValue)
    end
  end
end

module Creme
  class Interpreter
    register_library ["creme", "builtin", "complex"], Creme::R7RS::Complex
  end
end
