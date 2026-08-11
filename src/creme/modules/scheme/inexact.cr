# ===========================================================================
# (scheme inexact)
# ===========================================================================
#
# (scheme inexact) is the R7RS transcendentals (Creme::Builtins::MathLibrary,
# shared with the richer (creme math) — see modules/creme/math.cr) plus the
# inexact-specific sqrt / finite? / infinite? / nan? defined here. Both
# register_module calls' returns are the export list, so there is no
# hand-maintained subset constant.

module Creme::R7RS::InexactExtra
  extend self
  include Creme::BuiltinHelpers

  # Exact perfect-square fast path ahead of the float fallback: (sqrt 4)
  # is exact 2, not inexact 2.0. (sqrt 2) stays inexact (irrational, no
  # exact representation). Shares its integer-sqrt logic
  # (exact_integer_sqrt_pair, in BuiltinHelpers) with (scheme base)'s
  # exact-integer-sqrt builtin rather than duplicating it.
  @[Creme::SchemeFn("sqrt", min: 1, max: 1)]
  def sqrt(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    if (v.is_a?(SchemeInt) || v.is_a?(SchemeBigInt)) && v.value >= 0
      root, rem = exact_integer_sqrt_pair(v.value)
      rem == 0 ? Creme.int_value(root).as(SchemeValue) : SchemeFloat.new(Math.sqrt(Creme.as_f64(v, "sqrt"))).as(SchemeValue)
    elsif v.is_a?(SchemeComplex)
      complex_result(*Creme::ComplexMath.sqrt(*complex_parts(v, "sqrt")))
    elsif number?(v) && Creme.as_f64(v, "sqrt") < 0
      # sqrt of a negative real is complex, per R7RS — the magnitude's
      # square root goes on the imaginary axis.
      SchemeComplex.make(SchemeFloat.new(0.0), SchemeFloat.new(Math.sqrt(-Creme.as_f64(v, "sqrt")))).as(SchemeValue)
    else
      SchemeFloat.new(Math.sqrt(Creme.as_f64(v, "sqrt")))
    end
  end

  @[Creme::SchemeFn("nan?", min: 1, max: 1)]
  def nan_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    SchemeBool.of(v.is_a?(SchemeFloat) && v.value.nan?)
  end

  @[Creme::SchemeFn("infinite?", min: 1, max: 1)]
  def infinite_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    SchemeBool.of(v.is_a?(SchemeFloat) && v.value.infinite? != nil)
  end

  @[Creme::SchemeFn("finite?", min: 1, max: 1)]
  def finite_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    SchemeBool.of(!v.is_a?(SchemeFloat) || v.value.finite?)
  end
end

module Creme
  class Interpreter
    register_library ["creme", "builtin", "inexact"] do |env|
      register_module(Creme::Builtins::MathLibrary, env) +
        register_module(Creme::R7RS::InexactExtra, env)
    end
  end
end
