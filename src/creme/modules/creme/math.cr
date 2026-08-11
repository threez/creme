# ===========================================================================
# math module: transcendental functions and constants
# ===========================================================================
#
# MathLibrary holds exactly the transcendentals R7RS's (scheme inexact)
# specifies (sin/cos/tan/asin/acos/atan/exp/log) — so (scheme inexact)
# (modules/scheme/inexact.cr) registers it directly and derives its exports.
# MathExtra holds the creme-only richer surface (log2/log10/atan2/pow/hypot);
# (creme math) registers BOTH plus the pi/e constants.

module Creme::Builtins::MathLibrary
  extend self
  include Creme::BuiltinHelpers

  @[Creme::SchemeFn("sin", min: 1, max: 1)]
  def sin(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    return complex_result(*Creme::ComplexMath.sin(*complex_parts(v, "sin"))) if v.is_a?(SchemeComplex)
    SchemeFloat.new(Math.sin(Creme.as_f64(v, "sin")))
  end

  @[Creme::SchemeFn("cos", min: 1, max: 1)]
  def cos(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    return complex_result(*Creme::ComplexMath.cos(*complex_parts(v, "cos"))) if v.is_a?(SchemeComplex)
    SchemeFloat.new(Math.cos(Creme.as_f64(v, "cos")))
  end

  @[Creme::SchemeFn("tan", min: 1, max: 1)]
  def tan(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    return complex_result(*Creme::ComplexMath.tan(*complex_parts(v, "tan"))) if v.is_a?(SchemeComplex)
    SchemeFloat.new(Math.tan(Creme.as_f64(v, "tan")))
  end

  # (asin x) for a real |x| > 1 is genuinely complex (its correct value
  # doesn't fit on the real line) — same "real input, complex-valued
  # result" treatment sqrt already gives negative reals.
  @[Creme::SchemeFn("asin", min: 1, max: 1)]
  def asin(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    return complex_result(*Creme::ComplexMath.asin(*complex_parts(v, "asin"))) if v.is_a?(SchemeComplex)
    x = Creme.as_f64(v, "asin")
    return complex_result(*Creme::ComplexMath.asin(x, 0.0)) if x.abs > 1.0
    SchemeFloat.new(Math.asin(x))
  end

  @[Creme::SchemeFn("acos", min: 1, max: 1)]
  def acos(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    return complex_result(*Creme::ComplexMath.acos(*complex_parts(v, "acos"))) if v.is_a?(SchemeComplex)
    x = Creme.as_f64(v, "acos")
    return complex_result(*Creme::ComplexMath.acos(x, 0.0)) if x.abs > 1.0
    SchemeFloat.new(Math.acos(x))
  end

  @[Creme::SchemeFn("atan", min: 1, max: 1)]
  def atan(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    return complex_result(*Creme::ComplexMath.atan(*complex_parts(v, "atan"))) if v.is_a?(SchemeComplex)
    SchemeFloat.new(Math.atan(Creme.as_f64(v, "atan")))
  end

  # (log x) for a negative real x is genuinely complex (log|x| + i*pi) —
  # same real-input-complex-result treatment as sqrt/asin/acos above. The
  # optional explicit-base 2-argument form stays real-only, same as native.
  @[Creme::SchemeFn("log", min: 1, max: 2)]
  def log(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    if args.size == 1
      return complex_result(*Creme::ComplexMath.log(*complex_parts(v, "log"))) if v.is_a?(SchemeComplex)
      x = Creme.as_f64(v, "log")
      return complex_result(*Creme::ComplexMath.log(x, 0.0)) if x < 0
      return SchemeFloat.new(Math.log(x))
    end
    x = Creme.as_f64(v, "log")
    SchemeFloat.new(Math.log(x) / Math.log(Creme.as_f64(args[1], "log")))
  end

  @[Creme::SchemeFn("exp", min: 1, max: 1)]
  def exp(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    return complex_result(*Creme::ComplexMath.exp(*complex_parts(v, "exp"))) if v.is_a?(SchemeComplex)
    SchemeFloat.new(Math.exp(Creme.as_f64(v, "exp")))
  end
end

# creme-only richer math surface, beyond R7RS's (scheme inexact) contract.
module Creme::Builtins::MathExtra
  extend self
  include Creme::BuiltinHelpers

  @[Creme::SchemeFn("log2", min: 1, max: 1)]
  def log2(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeFloat.new(Math.log2(Creme.as_f64(args[0], "log2")))
  end

  @[Creme::SchemeFn("log10", min: 1, max: 1)]
  def log10(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeFloat.new(Math.log10(Creme.as_f64(args[0], "log10")))
  end

  @[Creme::SchemeFn("atan2", min: 2, max: 2)]
  def atan2(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeFloat.new(Math.atan2(Creme.as_f64(args[0], "atan2"), Creme.as_f64(args[1], "atan2")))
  end

  @[Creme::SchemeFn("pow", min: 2, max: 2)]
  def pow(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeFloat.new(Creme.as_f64(args[0], "pow") ** Creme.as_f64(args[1], "pow"))
  end

  @[Creme::SchemeFn("hypot", min: 2, max: 2)]
  def hypot(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeFloat.new(Math.hypot(Creme.as_f64(args[0], "hypot"), Creme.as_f64(args[1], "hypot")))
  end

  # Raw IEEE754 bit-level access — for a Scheme-level caller that needs
  # to encode/decode a float's exact 64-bit representation itself (e.g.
  # bootstrap/compiler.scm's ICE serializer, which otherwise has no way
  # to build a general float encoder without bitwise primitives).
  # Float64/Int64 are both 8 bytes, so `unsafe_as` is an exact bit-level
  # reinterpret cast — not a numeric conversion — in both directions.
  @[Creme::SchemeFn("flonum->bits", min: 1, max: 1)]
  def flonum_to_bits(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    f = args[0].as?(SchemeFloat) || raise SchemeRuntimeError.new("flonum->bits: expected a float, got #{args[0].write_string}")
    SchemeInt.new(f.value.unsafe_as(Int64))
  end

  @[Creme::SchemeFn("bits->flonum", min: 1, max: 1)]
  def bits_to_flonum(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    # args[0].as?(SchemeInt) — not SchemeBigInt — already rejects anything
    # that isn't a genuine 8-byte Int64: unsafe_as reinterprets raw bytes
    # at this exact size, which is only meaningful (and safe) for that.
    i = args[0].as?(SchemeInt) || raise SchemeRuntimeError.new("bits->flonum: expected an exact integer, got #{args[0].write_string}")
    SchemeFloat.new(i.value.unsafe_as(Float64))
  end
end

module Creme
  class Interpreter
    # pi/e are value constants, not procedures — Crystal has no macro-level
    # introspection for annotations on individual constants (only on
    # types/methods/ivars), so these still need an explicit env.define here
    # rather than a @[Creme::SchemeFn]-style annotation.
    register_library ["creme", "builtin", "math"] do |env|
      names = register_module(Creme::Builtins::MathLibrary, env) +
              register_module(Creme::Builtins::MathExtra, env)
      env.define("pi", SchemeFloat.new(Math::PI))
      env.define("e", SchemeFloat.new(Math::E))
      names + ["pi", "e"]
    end
  end
end
