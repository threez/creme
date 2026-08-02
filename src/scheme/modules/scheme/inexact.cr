# ===========================================================================
# (scheme inexact)
# ===========================================================================
#
# (scheme inexact) is the R7RS transcendentals (Scheme::Builtins::MathLibrary,
# shared with the richer (creme math) — see modules/creme/math.cr) plus the
# inexact-specific sqrt / finite? / infinite? / nan? defined here. Both
# register_module calls' returns are the export list, so there is no
# hand-maintained subset constant.

module Scheme::Builtins::InexactExtra
  extend self
  include Scheme::BuiltinHelpers

  # Exact perfect-square fast path ahead of the float fallback: (sqrt 4)
  # is exact 2, not inexact 2.0. (sqrt 2) stays inexact (irrational, no
  # exact representation). Shares its integer-sqrt logic
  # (exact_integer_sqrt_pair, in BuiltinHelpers) with (scheme base)'s
  # exact-integer-sqrt builtin rather than duplicating it.
  @[Scheme::SchemeFn("sqrt", min: 1, max: 1)]
  def sqrt(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    if v.is_a?(SchemeInt) && v.value >= 0
      root, rem = exact_integer_sqrt_pair(v.value)
      rem == 0 ? SchemeInt.new(root).as(SchemeValue) : SchemeFloat.new(Math.sqrt(Scheme.as_f64(v, "sqrt"))).as(SchemeValue)
    elsif number?(v) && !v.is_a?(SchemeComplex) && Scheme.as_f64(v, "sqrt") < 0
      # sqrt of a negative real is complex, per R7RS — the magnitude's
      # square root goes on the imaginary axis.
      SchemeComplex.make(SchemeFloat.new(0.0), SchemeFloat.new(Math.sqrt(-Scheme.as_f64(v, "sqrt")))).as(SchemeValue)
    else
      SchemeFloat.new(Math.sqrt(Scheme.as_f64(v, "sqrt")))
    end
  end

  @[Scheme::SchemeFn("nan?", min: 1, max: 1)]
  def nan_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    SchemeBool.of(v.is_a?(SchemeFloat) && v.value.nan?)
  end

  @[Scheme::SchemeFn("infinite?", min: 1, max: 1)]
  def infinite_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    SchemeBool.of(v.is_a?(SchemeFloat) && v.value.infinite? != nil)
  end

  @[Scheme::SchemeFn("finite?", min: 1, max: 1)]
  def finite_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    SchemeBool.of(!v.is_a?(SchemeFloat) || v.value.finite?)
  end
end

module Scheme
  class Interpreter
    register_library ["creme", "builtin", "inexact"] do |env|
      register_module(Scheme::Builtins::MathLibrary, env) +
        register_module(Scheme::Builtins::InexactExtra, env)
    end
  end
end
