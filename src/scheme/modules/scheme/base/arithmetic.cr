# ===========================================================================
# (scheme base): arithmetic, exactness conversions, comparisons
# ===========================================================================

module Scheme::Builtins::Arithmetic
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("+", min: 0, max: -1)]
  def add(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    acc : SchemeValue = SchemeInt.new(0_i64)
    args.each { |arg| acc = num_add(acc, arg, "+") }
    acc
  end

  @[Scheme::SchemeFn("*", min: 0, max: -1)]
  def mul(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    acc : SchemeValue = SchemeInt.new(1_i64)
    args.each { |arg| acc = num_mul(acc, arg, "*") }
    acc
  end

  @[Scheme::SchemeFn("-", min: 1, max: -1)]
  def sub(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    if args.size == 1
      num_sub(SchemeInt.new(0_i64), args[0], "-")
    else
      acc = args[0]
      (1...args.size).each { |i| acc = num_sub(acc, args[i], "-") }
      acc
    end
  end

  @[Scheme::SchemeFn("/", min: 1, max: -1)]
  def div(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    if args.size == 1
      divide(SchemeInt.new(1_i64), args[0])
    else
      acc = args[0]
      (1...args.size).each { |i| acc = divide(acc, args[i]) }
      acc
    end
  end

  @[Scheme::SchemeFn("modulo", min: 2, max: 2)]
  def modulo(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    a = int_arg(args[0], "modulo")
    b = int_arg(args[1], "modulo")
    raise SchemeRuntimeError.new("modulo: division by zero") if b == 0
    begin
      SchemeInt.new(a % b)
    rescue ArgumentError | OverflowError
      raise SchemeRuntimeError.new("modulo: integer overflow")
    end
  end

  @[Scheme::SchemeFn("remainder", min: 2, max: 2)]
  def remainder(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    a = int_arg(args[0], "remainder")
    b = int_arg(args[1], "remainder")
    raise SchemeRuntimeError.new("remainder: division by zero") if b == 0
    SchemeInt.new(a.remainder(b))
  end

  @[Scheme::SchemeFn("quotient", min: 2, max: 2)]
  def quotient(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    a = int_arg(args[0], "quotient")
    b = int_arg(args[1], "quotient")
    raise SchemeRuntimeError.new("quotient: division by zero") if b == 0
    begin
      SchemeInt.new(a.tdiv(b)) # truncate toward zero
    rescue ArgumentError | OverflowError
      raise SchemeRuntimeError.new("quotient: integer overflow")
    end
  end

  # truncate-quotient/truncate-remainder are exactly quotient/remainder
  # under R7RS's explicit names (both already truncate toward zero);
  # floor-quotient/floor-remainder match modulo's floor-toward-negative-
  # infinity rounding. The four /-suffixed procedures return both parts
  # at once via `values`.
  @[Scheme::SchemeFn("truncate-quotient", min: 2, max: 2)]
  def truncate_quotient(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    interp.apply(env.get("quotient"), args)
  end

  @[Scheme::SchemeFn("truncate-remainder", min: 2, max: 2)]
  def truncate_remainder(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    interp.apply(env.get("remainder"), args)
  end

  @[Scheme::SchemeFn("floor-quotient", min: 2, max: 2)]
  def floor_quotient(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    a = int_arg(args[0], "floor-quotient")
    b = int_arg(args[1], "floor-quotient")
    raise SchemeRuntimeError.new("floor-quotient: division by zero") if b == 0
    begin
      SchemeInt.new(a // b)
    rescue ArgumentError | OverflowError
      raise SchemeRuntimeError.new("floor-quotient: integer overflow")
    end
  end

  @[Scheme::SchemeFn("floor-remainder", min: 2, max: 2)]
  def floor_remainder(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    interp.apply(env.get("modulo"), args)
  end

  @[Scheme::SchemeFn("truncate/", min: 2, max: 2)]
  def truncate_slash(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeValues.new([interp.apply(env.get("truncate-quotient"), args), interp.apply(env.get("truncate-remainder"), args)]).as(SchemeValue)
  end

  @[Scheme::SchemeFn("floor/", min: 2, max: 2)]
  def floor_slash(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeValues.new([interp.apply(env.get("floor-quotient"), args), interp.apply(env.get("floor-remainder"), args)]).as(SchemeValue)
  end

  @[Scheme::SchemeFn("abs", min: 1, max: 1)]
  def abs(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    case v
    when SchemeInt
      begin
        SchemeInt.new(v.value.abs)
      rescue OverflowError
        raise SchemeRuntimeError.new("abs: integer overflow")
      end
    when SchemeFloat then SchemeFloat.new(v.value.abs)
    else                  raise SchemeRuntimeError.new("abs: expected number, got #{v.write_string}")
    end
  end

  @[Scheme::SchemeFn("min", min: 1, max: -1)]
  def min(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    fold_minmax(args, "min", true)
  end

  @[Scheme::SchemeFn("max", min: 1, max: -1)]
  def max(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    fold_minmax(args, "max", false)
  end

  @[Scheme::SchemeFn("gcd", min: 0, max: -1)]
  def gcd(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    result = args.reduce(0_i64) { |acc, v| Scheme.int_gcd(acc, int_arg(v, "gcd")) }
    SchemeInt.new(result).as(SchemeValue)
  end

  @[Scheme::SchemeFn("lcm", min: 0, max: -1)]
  def lcm(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    result = args.reduce(1_i64) { |acc, v| Scheme.int_lcm(acc, int_arg(v, "lcm")) }
    SchemeInt.new(result).as(SchemeValue)
  rescue OverflowError
    raise SchemeRuntimeError.new("lcm: integer overflow")
  end

  # (expt 2 -1) is now exact 1/2, not inexact 0.5: a negative integer
  # exponent of an exact integer base routes through the same positive-
  # exponent path (expt_int_pow) and SchemeRational.make, rather than
  # falling back to float power.
  @[Scheme::SchemeFn("expt", min: 2, max: 2)]
  def expt(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    base = args[0]
    ex = args[1]
    if base.is_a?(SchemeInt) && ex.is_a?(SchemeInt)
      if ex.value >= 0
        SchemeInt.new(expt_int_pow(base.value, ex.value))
      else
        begin
          SchemeRational.make(1_i64, expt_int_pow(base.value, -ex.value))
        rescue OverflowError
          raise SchemeRuntimeError.new("expt: integer overflow")
        end
      end
    else
      SchemeFloat.new(Scheme.as_f64(base, "expt") ** Scheme.as_f64(ex, "expt"))
    end
  end

  # Exact perfect-square fast path ahead of the float fallback: (sqrt 4)
  # is now exact 2, not inexact 2.0. (sqrt 2) stays inexact (irrational,
  # no exact representation). Shares its integer-sqrt logic with the
  # exact-integer-sqrt builtin below rather than duplicating it.
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

  @[Scheme::SchemeFn("exact-integer-sqrt", min: 1, max: 1)]
  def exact_integer_sqrt(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    n = int_arg(args[0], "exact-integer-sqrt")
    raise SchemeRuntimeError.new("exact-integer-sqrt: expected a non-negative integer") if n < 0
    root, rem = exact_integer_sqrt_pair(n)
    SchemeValues.new([SchemeInt.new(root).as(SchemeValue), SchemeInt.new(rem).as(SchemeValue)])
  end

  @[Scheme::SchemeFn("inexact", min: 1, max: 1)]
  def inexact(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeFloat.new(Scheme.as_f64(args[0], "inexact"))
  end

  @[Scheme::SchemeFn("exact", min: 1, max: 1)]
  def exact(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    to_exact(args[0])
  end

  # On a float, round-trips through the exact equivalent (per R7RS):
  # (numerator 2.5) is 5.0, (denominator 2.5) is 2.0 — both stay inexact.
  @[Scheme::SchemeFn("numerator", min: 1, max: 1)]
  def numerator(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    case v
    when SchemeInt      then v.as(SchemeValue)
    when SchemeRational then SchemeInt.new(v.numerator).as(SchemeValue)
    when SchemeFloat
      n, _ = Scheme.as_ratio(to_exact(v))
      SchemeFloat.new(n.to_f64).as(SchemeValue)
    else raise SchemeRuntimeError.new("numerator: expected number, got #{v.write_string}")
    end
  end

  @[Scheme::SchemeFn("denominator", min: 1, max: 1)]
  def denominator(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    case v
    when SchemeInt      then SchemeInt.new(1_i64).as(SchemeValue)
    when SchemeRational then SchemeInt.new(v.denominator).as(SchemeValue)
    when SchemeFloat
      _, d = Scheme.as_ratio(to_exact(v))
      SchemeFloat.new(d.to_f64).as(SchemeValue)
    else raise SchemeRuntimeError.new("denominator: expected number, got #{v.write_string}")
    end
  end

  # R7RS's floor/ceiling/truncate/round are generic over the numeric
  # tower: an exact (integer) argument returns itself exactly, an
  # inexact (float) argument is rounded and stays inexact.
  @[Scheme::SchemeFn("floor", min: 1, max: 1)]
  def floor(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    round_like(args[0], "floor", ->rational_floor(Int64, Int64), &.floor)
  end

  @[Scheme::SchemeFn("ceiling", min: 1, max: 1)]
  def ceiling(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    round_like(args[0], "ceiling", ->rational_ceiling(Int64, Int64), &.ceil)
  end

  @[Scheme::SchemeFn("truncate", min: 1, max: 1)]
  def truncate(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    round_like(args[0], "truncate", ->rational_truncate(Int64, Int64), &.trunc)
  end

  @[Scheme::SchemeFn("round", min: 1, max: 1)]
  def round(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    round_like(args[0], "round", ->rational_round(Int64, Int64), &.round(:ties_even))
  end

  @[Scheme::SchemeFn("=", min: 1, max: -1)]
  def num_eq(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    num_chain(args, "=") { |cmp| cmp == 0 }
  end

  @[Scheme::SchemeFn("<", min: 1, max: -1)]
  def num_lt(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    num_chain(args, "<") { |cmp| cmp < 0 }
  end

  @[Scheme::SchemeFn(">", min: 1, max: -1)]
  def num_gt(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    num_chain(args, ">") { |cmp| cmp > 0 }
  end

  @[Scheme::SchemeFn("<=", min: 1, max: -1)]
  def num_le(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    num_chain(args, "<=") { |cmp| cmp <= 0 }
  end

  @[Scheme::SchemeFn(">=", min: 1, max: -1)]
  def num_ge(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    num_chain(args, ">=") { |cmp| cmp >= 0 }
  end

  @[Scheme::SchemeFn("not", min: 1, max: 1)]
  def not(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(!Scheme.truthy?(args[0]))
  end

  @[Scheme::SchemeFn("eq?", min: 2, max: 2)]
  def eq_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(Scheme.scheme_eqv?(args[0], args[1]))
  end

  @[Scheme::SchemeFn("eqv?", min: 2, max: 2)]
  def eqv_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(Scheme.scheme_eqv?(args[0], args[1]))
  end

  @[Scheme::SchemeFn("equal?", min: 2, max: 2)]
  def equal_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(Scheme.scheme_equal?(args[0], args[1]))
  end
end

module Scheme
  class Interpreter
    private def install_arithmetic(env : Env) : Nil
      register_module(Scheme::Builtins::Arithmetic, env)
    end
  end
end
