# ===========================================================================
# (scheme base): type predicates
# ===========================================================================
#
# nan?/infinite?/finite? live in (scheme inexact) and macro? in
# (creme introspection) — each defined in that library's own module file.

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

  # zero?/positive?/negative? — the sign predicates, real builtins (rather than
  # prelude closures like `(= n 0)`) so a direct `(zero? n)` fuses into
  # Op::CmpZero, and so redefinition-guarded fusion has a Builtin to key on.
  # Implemented via the same `num_chain` the =/>/< builtins use, so the
  # numeric-tower semantics stay identical (only the error's `who` differs).
  # The VM fast-paths int/float and deopts here for rational/complex/errors.
  @[Scheme::SchemeFn("zero?", min: 1, max: 1)]
  def zero_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    num_chain([args[0], SchemeInt.new(0_i64)], "zero?") { |cmp| cmp == 0 }
  end

  @[Scheme::SchemeFn("positive?", min: 1, max: 1)]
  def positive_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    num_chain([args[0], SchemeInt.new(0_i64)], "positive?") { |cmp| cmp > 0 }
  end

  @[Scheme::SchemeFn("negative?", min: 1, max: 1)]
  def negative_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    num_chain([args[0], SchemeInt.new(0_i64)], "negative?") { |cmp| cmp < 0 }
  end

  # even?/odd?: R7RS integer parity predicates, real builtins (rather than
  # prelude closures going through exact-integer-part + modulo + =). Accept
  # exact integers and integer-valued floats (e.g. 4.0); anything else is an
  # error.
  @[Scheme::SchemeFn("even?", min: 1, max: 1)]
  def even_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(integer_value_for(args[0], "even?").even?)
  end

  @[Scheme::SchemeFn("odd?", min: 1, max: 1)]
  def odd_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(integer_value_for(args[0], "odd?").odd?)
  end

  private def integer_value_for(v : SchemeValue, who : String) : Int64
    case v
    when SchemeInt
      v.value
    when SchemeFloat
      f = v.value
      unless f.finite? && f == f.trunc && Int64::MIN.to_f64 <= f <= Int64::MAX.to_f64
        raise SchemeRuntimeError.new("#{who}: expected integer, got #{v.write_string}")
      end
      f.to_i64
    else
      raise SchemeRuntimeError.new("#{who}: expected integer, got #{v.write_string}")
    end
  end

  @[Scheme::SchemeFn("exact?", min: 1, max: 1)]
  def exact_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(Scheme.exact?(args[0]))
  end

  @[Scheme::SchemeFn("inexact?", min: 1, max: 1)]
  def inexact_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(Scheme.inexact?(args[0]))
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
end

module Scheme
  class Interpreter
    private def install_predicates(env : Env) : Array(String)
      register_module(Scheme::Builtins::Predicates, env)
    end
  end
end
