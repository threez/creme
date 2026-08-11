# ===========================================================================
# (scheme base): arithmetic, exactness conversions, comparisons
# ===========================================================================

module Creme::R7RS::Arithmetic
  extend self
  include Creme::BuiltinHelpers

  @[Creme::SchemeFn("+", min: 0, max: -1)]
  def add(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    acc : SchemeValue = SchemeInt.new(0_i64)
    args.each { |arg| acc = num_add(acc, arg, "+") }
    acc
  end

  @[Creme::SchemeFn("*", min: 0, max: -1)]
  def mul(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    acc : SchemeValue = SchemeInt.new(1_i64)
    args.each { |arg| acc = num_mul(acc, arg, "*") }
    acc
  end

  @[Creme::SchemeFn("-", min: 1, max: -1)]
  def sub(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    if args.size == 1
      num_sub(SchemeInt.new(0_i64), args[0], "-")
    else
      acc = args[0]
      (1...args.size).each { |i| acc = num_sub(acc, args[i], "-") }
      acc
    end
  end

  @[Creme::SchemeFn("/", min: 1, max: -1)]
  def div(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    if args.size == 1
      divide(SchemeInt.new(1_i64), args[0])
    else
      acc = args[0]
      (1...args.size).each { |i| acc = divide(acc, args[i]) }
      acc
    end
  end

  @[Creme::SchemeFn("modulo", min: 2, max: 2)]
  def modulo(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    a = rat_arg(args[0], "modulo")
    b = rat_arg(args[1], "modulo")
    raise SchemeRuntimeError.new("modulo: division by zero") if b == 0
    Creme.int_value(Creme.rat_mod(a, b))
  end

  @[Creme::SchemeFn("remainder", min: 2, max: 2)]
  def remainder(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    a = rat_arg(args[0], "remainder")
    b = rat_arg(args[1], "remainder")
    raise SchemeRuntimeError.new("remainder: division by zero") if b == 0
    Creme.int_value(Creme.rat_remainder(a, b))
  end

  @[Creme::SchemeFn("quotient", min: 2, max: 2)]
  def quotient(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    a = rat_arg(args[0], "quotient")
    b = rat_arg(args[1], "quotient")
    raise SchemeRuntimeError.new("quotient: division by zero") if b == 0
    Creme.int_value(Creme.rat_tdiv(a, b)) # truncate toward zero
  end

  # truncate-quotient/truncate-remainder are exactly quotient/remainder
  # under R7RS's explicit names (both already truncate toward zero);
  # floor-quotient/floor-remainder match modulo's floor-toward-negative-
  # infinity rounding. The four /-suffixed procedures return both parts
  # at once via `values`.
  @[Creme::SchemeFn("truncate-quotient", min: 2, max: 2)]
  def truncate_quotient(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    interp.apply(env.get("quotient"), args)
  end

  @[Creme::SchemeFn("truncate-remainder", min: 2, max: 2)]
  def truncate_remainder(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    interp.apply(env.get("remainder"), args)
  end

  @[Creme::SchemeFn("floor-quotient", min: 2, max: 2)]
  def floor_quotient(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    a = rat_arg(args[0], "floor-quotient")
    b = rat_arg(args[1], "floor-quotient")
    raise SchemeRuntimeError.new("floor-quotient: division by zero") if b == 0
    Creme.int_value(Creme.int_div(a, b))
  end

  @[Creme::SchemeFn("floor-remainder", min: 2, max: 2)]
  def floor_remainder(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    interp.apply(env.get("modulo"), args)
  end

  @[Creme::SchemeFn("truncate/", min: 2, max: 2)]
  def truncate_slash(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeValues.new([interp.apply(env.get("truncate-quotient"), args), interp.apply(env.get("truncate-remainder"), args)]).as(SchemeValue)
  end

  @[Creme::SchemeFn("floor/", min: 2, max: 2)]
  def floor_slash(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeValues.new([interp.apply(env.get("floor-quotient"), args), interp.apply(env.get("floor-remainder"), args)]).as(SchemeValue)
  end

  @[Creme::SchemeFn("abs", min: 1, max: 1)]
  def abs(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    case v
    when SchemeInt    then Creme.int_value(Creme.rat_abs(v.value))
    when SchemeBigInt then Creme.int_value(Creme.rat_abs(v.value))
    when SchemeFloat  then SchemeFloat.new(v.value.abs)
    else                   raise SchemeRuntimeError.new("abs: expected number, got #{v.write_string}")
    end
  end

  @[Creme::SchemeFn("min", min: 1, max: -1)]
  def min(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    fold_minmax(args, "min", true)
  end

  @[Creme::SchemeFn("max", min: 1, max: -1)]
  def max(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    fold_minmax(args, "max", false)
  end

  @[Creme::SchemeFn("gcd", min: 0, max: -1)]
  def gcd(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    result = args.reduce(0_i64.as(RatInt)) { |acc, v| Creme.rat_gcd(acc, rat_arg(v, "gcd")) }
    Creme.int_value(result).as(SchemeValue)
  end

  @[Creme::SchemeFn("lcm", min: 0, max: -1)]
  def lcm(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    result = args.reduce(1_i64.as(RatInt)) { |acc, v| Creme.rat_lcm(acc, rat_arg(v, "lcm")) }
    Creme.int_value(result).as(SchemeValue)
  end

  # (expt 2 -1) is now exact 1/2, not inexact 0.5: a negative integer
  # exponent of an exact integer base routes through the same positive-
  # exponent path (expt_int_pow) and SchemeRational.make, rather than
  # falling back to float power. Neither path can overflow anymore —
  # expt_int_pow escalates to BigInt itself.
  @[Creme::SchemeFn("expt", min: 2, max: 2)]
  # ameba:disable Metrics/CyclomaticComplexity
  def expt(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    base = args[0]
    ex = args[1]
    if (base.is_a?(SchemeInt) || base.is_a?(SchemeBigInt)) && ex.is_a?(SchemeInt)
      exv = ex.value
      basev = Creme.rat_of(base)
      if exv >= 0
        Creme.int_value(expt_int_pow(basev, exv))
      else
        SchemeRational.make(1_i64, expt_int_pow(basev, -exv))
      end
    elsif base.is_a?(SchemeComplex) || ex.is_a?(SchemeComplex) ||
          (!base.is_a?(SchemeComplex) && number?(base) && Creme.as_f64(base, "expt") < 0 && !integer_valued?(ex))
      # A negative real base with a non-integer real exponent (or either
      # operand already complex) is genuinely complex — e.g. (expt -8 1/3)
      # — rather than the NaN a plain float pow would silently produce.
      br, bi = complex_parts(base, "expt")
      er, ei = complex_parts(ex, "expt")
      complex_result(*Creme::ComplexMath.pow(br, bi, er, ei))
    else
      SchemeFloat.new(Creme.as_f64(base, "expt") ** Creme.as_f64(ex, "expt"))
    end
  end

  @[Creme::SchemeFn("exact-integer-sqrt", min: 1, max: 1)]
  def exact_integer_sqrt(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    n = rat_arg(args[0], "exact-integer-sqrt")
    raise SchemeRuntimeError.new("exact-integer-sqrt: expected a non-negative integer") if n < 0
    root, rem = exact_integer_sqrt_pair(n)
    SchemeValues.new([Creme.int_value(root).as(SchemeValue), Creme.int_value(rem).as(SchemeValue)])
  end

  @[Creme::SchemeFn("inexact", min: 1, max: 1)]
  def inexact(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeFloat.new(Creme.as_f64(args[0], "inexact"))
  end

  @[Creme::SchemeFn("exact", min: 1, max: 1)]
  def exact(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    to_exact(args[0])
  end

  # On a float, round-trips through the exact equivalent (per R7RS):
  # (numerator 2.5) is 5.0, (denominator 2.5) is 2.0 — both stay inexact.
  @[Creme::SchemeFn("numerator", min: 1, max: 1)]
  def numerator(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    case v
    when SchemeInt, SchemeBigInt then v.as(SchemeValue)
    when SchemeRational          then Creme.int_value(v.numerator).as(SchemeValue)
    when SchemeFloat
      n, _ = Creme.as_ratio(to_exact(v))
      SchemeFloat.new(n.to_f64).as(SchemeValue)
    else raise SchemeRuntimeError.new("numerator: expected number, got #{v.write_string}")
    end
  end

  @[Creme::SchemeFn("denominator", min: 1, max: 1)]
  def denominator(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    case v
    when SchemeInt, SchemeBigInt then SchemeInt.new(1_i64).as(SchemeValue)
    when SchemeRational          then Creme.int_value(v.denominator).as(SchemeValue)
    when SchemeFloat
      _, d = Creme.as_ratio(to_exact(v))
      SchemeFloat.new(d.to_f64).as(SchemeValue)
    else raise SchemeRuntimeError.new("denominator: expected number, got #{v.write_string}")
    end
  end

  # R7RS's floor/ceiling/truncate/round are generic over the numeric
  # tower: an exact (integer) argument returns itself exactly, an
  # inexact (float) argument is rounded and stays inexact.
  @[Creme::SchemeFn("floor", min: 1, max: 1)]
  def floor(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    round_like(args[0], "floor", ->rational_floor(RatInt, RatInt), &.floor)
  end

  @[Creme::SchemeFn("ceiling", min: 1, max: 1)]
  def ceiling(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    round_like(args[0], "ceiling", ->rational_ceiling(RatInt, RatInt), &.ceil)
  end

  @[Creme::SchemeFn("truncate", min: 1, max: 1)]
  def truncate(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    round_like(args[0], "truncate", ->rational_truncate(RatInt, RatInt), &.trunc)
  end

  @[Creme::SchemeFn("round", min: 1, max: 1)]
  def round(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    round_like(args[0], "round", ->rational_round(RatInt, RatInt), &.round(:ties_even))
  end

  @[Creme::SchemeFn("=", min: 1, max: -1)]
  def num_eq(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    num_chain(args, "=") { |cmp| cmp == 0 }
  end

  @[Creme::SchemeFn("<", min: 1, max: -1)]
  def num_lt(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    num_chain(args, "<") { |cmp| cmp < 0 }
  end

  @[Creme::SchemeFn(">", min: 1, max: -1)]
  def num_gt(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    num_chain(args, ">") { |cmp| cmp > 0 }
  end

  @[Creme::SchemeFn("<=", min: 1, max: -1)]
  def num_le(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    num_chain(args, "<=") { |cmp| cmp <= 0 }
  end

  @[Creme::SchemeFn(">=", min: 1, max: -1)]
  def num_ge(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    num_chain(args, ">=") { |cmp| cmp >= 0 }
  end

  @[Creme::SchemeFn("not", min: 1, max: 1)]
  def not(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(!Creme.truthy?(args[0]))
  end

  @[Creme::SchemeFn("eq?", min: 2, max: 2)]
  def eq_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(Creme.scheme_eqv?(args[0], args[1]))
  end

  @[Creme::SchemeFn("eqv?", min: 2, max: 2)]
  def eqv_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(Creme.scheme_eqv?(args[0], args[1]))
  end

  @[Creme::SchemeFn("equal?", min: 2, max: 2)]
  def equal_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(Creme.scheme_equal?(args[0], args[1]))
  end
end

module Creme
  class Interpreter
    private def install_arithmetic(env : Env) : Array(String)
      register_module(Creme::R7RS::Arithmetic, env)
    end
  end
end
