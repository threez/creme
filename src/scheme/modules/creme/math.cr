# ===========================================================================
# math module: transcendental functions and constants
# ===========================================================================
#
# MathLibrary holds exactly the transcendentals R7RS's (scheme inexact)
# specifies (sin/cos/tan/asin/acos/atan/exp/log) — so (scheme inexact)
# (modules/scheme/inexact.cr) registers it directly and derives its exports.
# MathExtra holds the creme-only richer surface (log2/log10/atan2/pow/hypot);
# (creme math) registers BOTH plus the pi/e constants.

module Scheme::Builtins::MathLibrary
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("sin", min: 1, max: 1)]
  def sin(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeFloat.new(Math.sin(Scheme.as_f64(args[0], "sin")))
  end

  @[Scheme::SchemeFn("cos", min: 1, max: 1)]
  def cos(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeFloat.new(Math.cos(Scheme.as_f64(args[0], "cos")))
  end

  @[Scheme::SchemeFn("tan", min: 1, max: 1)]
  def tan(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeFloat.new(Math.tan(Scheme.as_f64(args[0], "tan")))
  end

  @[Scheme::SchemeFn("asin", min: 1, max: 1)]
  def asin(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeFloat.new(Math.asin(Scheme.as_f64(args[0], "asin")))
  end

  @[Scheme::SchemeFn("acos", min: 1, max: 1)]
  def acos(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeFloat.new(Math.acos(Scheme.as_f64(args[0], "acos")))
  end

  @[Scheme::SchemeFn("atan", min: 1, max: 1)]
  def atan(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeFloat.new(Math.atan(Scheme.as_f64(args[0], "atan")))
  end

  @[Scheme::SchemeFn("log", min: 1, max: 2)]
  def log(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    x = Scheme.as_f64(args[0], "log")
    if args.size == 2
      SchemeFloat.new(Math.log(x) / Math.log(Scheme.as_f64(args[1], "log")))
    else
      SchemeFloat.new(Math.log(x))
    end
  end

  @[Scheme::SchemeFn("exp", min: 1, max: 1)]
  def exp(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeFloat.new(Math.exp(Scheme.as_f64(args[0], "exp")))
  end
end

# creme-only richer math surface, beyond R7RS's (scheme inexact) contract.
module Scheme::Builtins::MathExtra
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("log2", min: 1, max: 1)]
  def log2(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeFloat.new(Math.log2(Scheme.as_f64(args[0], "log2")))
  end

  @[Scheme::SchemeFn("log10", min: 1, max: 1)]
  def log10(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeFloat.new(Math.log10(Scheme.as_f64(args[0], "log10")))
  end

  @[Scheme::SchemeFn("atan2", min: 2, max: 2)]
  def atan2(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeFloat.new(Math.atan2(Scheme.as_f64(args[0], "atan2"), Scheme.as_f64(args[1], "atan2")))
  end

  @[Scheme::SchemeFn("pow", min: 2, max: 2)]
  def pow(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeFloat.new(Scheme.as_f64(args[0], "pow") ** Scheme.as_f64(args[1], "pow"))
  end

  @[Scheme::SchemeFn("hypot", min: 2, max: 2)]
  def hypot(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeFloat.new(Math.hypot(Scheme.as_f64(args[0], "hypot"), Scheme.as_f64(args[1], "hypot")))
  end

  # Raw IEEE754 bit-level access — for a Scheme-level caller that needs
  # to encode/decode a float's exact 64-bit representation itself (e.g.
  # bootstrap/compiler.scm's SCB1 serializer, which otherwise has no way
  # to build a general float encoder without bitwise primitives).
  # Float64/Int64 are both 8 bytes, so `unsafe_as` is an exact bit-level
  # reinterpret cast — not a numeric conversion — in both directions.
  @[Scheme::SchemeFn("flonum->bits", min: 1, max: 1)]
  def flonum_to_bits(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    f = args[0].as?(SchemeFloat) || raise SchemeRuntimeError.new("flonum->bits: expected a float, got #{args[0].write_string}")
    SchemeInt.new(f.value.unsafe_as(Int64))
  end

  @[Scheme::SchemeFn("bits->flonum", min: 1, max: 1)]
  def bits_to_flonum(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    i = args[0].as?(SchemeInt) || raise SchemeRuntimeError.new("bits->flonum: expected an exact integer, got #{args[0].write_string}")
    SchemeFloat.new(i.value.unsafe_as(Float64))
  end
end

module Scheme
  class Interpreter
    # pi/e are value constants, not procedures — Crystal has no macro-level
    # introspection for annotations on individual constants (only on
    # types/methods/ivars), so these still need an explicit env.define here
    # rather than a @[Scheme::SchemeFn]-style annotation.
    register_library ["creme", "builtin", "math"] do |env|
      names = register_module(Scheme::Builtins::MathLibrary, env) +
              register_module(Scheme::Builtins::MathExtra, env)
      env.define("pi", SchemeFloat.new(Math::PI))
      env.define("e", SchemeFloat.new(Math::E))
      names + ["pi", "e"]
    end
  end
end
