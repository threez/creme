# ===========================================================================
# (scheme base): type predicates
# ===========================================================================

module Scheme::Builtins::Predicates
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("number?", min: 1, max: 1)]
  def number_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(number?(args[0]))
  end

  # real? is number? minus genuine complex values (a SchemeComplex is
  # never real by construction — SchemeComplex.make collapses an exact
  # zero imaginary part back to a bare real component).
  @[Scheme::SchemeFn("real?", min: 1, max: 1)]
  def real_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(number?(args[0]) && !args[0].is_a?(SchemeComplex))
  end

  # rational? is number? minus the non-finite floats (+inf.0/-inf.0/+nan.0).
  @[Scheme::SchemeFn("rational?", min: 1, max: 1)]
  def rational_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    SchemeBool.of(Scheme.exact?(v) || (v.is_a?(SchemeFloat) && v.value.finite?))
  end

  # integer? is about numeric VALUE, not representation: a whole-valued
  # float like 3.0 is an integer per R7RS. A SchemeRational is never a
  # whole number by construction (SchemeRational.make always collapses
  # those to SchemeInt), so its case is always false.
  @[Scheme::SchemeFn("integer?", min: 1, max: 1)]
  def integer_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    is_int =
      case v
      when SchemeInt      then true
      when SchemeRational then false
      when SchemeFloat    then v.value.finite? && v.value == v.value.to_i64.to_f64
      else                     false
      end
    SchemeBool.of(is_int)
  end

  @[Scheme::SchemeFn("exact-integer?", min: 1, max: 1)]
  def exact_integer_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(args[0].is_a?(SchemeInt))
  end

  @[Scheme::SchemeFn("exact?", min: 1, max: 1)]
  def exact_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(Scheme.exact?(args[0]))
  end

  @[Scheme::SchemeFn("inexact?", min: 1, max: 1)]
  def inexact_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(Scheme.inexact?(args[0]))
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

  @[Scheme::SchemeFn("square", min: 1, max: 1)]
  def square(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    interp.num_mul(args[0], args[0], "square")
  end

  @[Scheme::SchemeFn("symbol?", min: 1, max: 1)]
  def symbol_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(args[0].is_a?(SchemeSym))
  end

  @[Scheme::SchemeFn("string?", min: 1, max: 1)]
  def string_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(args[0].is_a?(SchemeStr))
  end

  @[Scheme::SchemeFn("boolean?", min: 1, max: 1)]
  def boolean_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(args[0].is_a?(SchemeBool))
  end

  @[Scheme::SchemeFn("char?", min: 1, max: 1)]
  def char_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(args[0].is_a?(SchemeChar))
  end

  @[Scheme::SchemeFn("procedure?", min: 1, max: 1)]
  def procedure_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    SchemeBool.of(v.is_a?(Builtin) || v.is_a?(BytecodeClosure) || v.is_a?(BytecodeCaseClosure))
  end

  @[Scheme::SchemeFn("macro?", min: 1, max: 1)]
  def macro_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(args[0].is_a?(Macro))
  end
end

module Scheme
  class Interpreter
    private def install_predicates(env : Env) : Nil
      register_module(Scheme::Builtins::Predicates, env)
    end
  end
end
