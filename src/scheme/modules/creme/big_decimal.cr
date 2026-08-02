# ===========================================================================
# bigdecimal module: arbitrary-precision decimal arithmetic
# ===========================================================================

require "big"

module Scheme
  class SchemeBigDecimal
    include SchemeBaseValue
    getter value : BigDecimal

    def initialize(@value : BigDecimal)
    end

    def to_display(io : IO) : Nil
      io << @value
    end
  end
end

module Scheme::Builtins::BigDecimalLibrary
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("string->bigdecimal", min: 1, max: 1)]
  def string_to_bigdecimal(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    s = bigdecimal_str_arg(args[0], "string->bigdecimal")
    SchemeBigDecimal.new(BigDecimal.new(s))
  rescue ex : Exception
    raise SchemeRuntimeError.new("string->bigdecimal: invalid decimal '#{s}'")
  end

  @[Scheme::SchemeFn("integer->bigdecimal", min: 1, max: 1)]
  def integer_to_bigdecimal(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    n = args[0]
    raise SchemeRuntimeError.new("integer->bigdecimal: expected integer, got #{n.write_string}") unless n.is_a?(SchemeInt)
    SchemeBigDecimal.new(BigDecimal.new(n.value))
  end

  @[Scheme::SchemeFn("bigdecimal-add", min: 2, max: 2)]
  def bigdecimal_add(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    a = bigdecimal_arg(args[0], "bigdecimal-add")
    b = bigdecimal_arg(args[1], "bigdecimal-add")
    SchemeBigDecimal.new(a + b)
  end

  @[Scheme::SchemeFn("bigdecimal-sub", min: 2, max: 2)]
  def bigdecimal_sub(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    a = bigdecimal_arg(args[0], "bigdecimal-sub")
    b = bigdecimal_arg(args[1], "bigdecimal-sub")
    SchemeBigDecimal.new(a - b)
  end

  @[Scheme::SchemeFn("bigdecimal-mul", min: 2, max: 2)]
  def bigdecimal_mul(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    a = bigdecimal_arg(args[0], "bigdecimal-mul")
    b = bigdecimal_arg(args[1], "bigdecimal-mul")
    SchemeBigDecimal.new(a * b)
  end

  @[Scheme::SchemeFn("bigdecimal-div", min: 2, max: 2)]
  def bigdecimal_div(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    a = bigdecimal_arg(args[0], "bigdecimal-div")
    b = bigdecimal_arg(args[1], "bigdecimal-div")
    raise SchemeRuntimeError.new("bigdecimal-div: division by zero") if b.zero?
    SchemeBigDecimal.new(a / b)
  end

  @[Scheme::SchemeFn("bigdecimal-neg", min: 1, max: 1)]
  def bigdecimal_neg(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBigDecimal.new(-bigdecimal_arg(args[0], "bigdecimal-neg"))
  end

  @[Scheme::SchemeFn("bigdecimal-compare", min: 2, max: 2)]
  def bigdecimal_compare(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    a = bigdecimal_arg(args[0], "bigdecimal-compare")
    b = bigdecimal_arg(args[1], "bigdecimal-compare")
    SchemeInt.new((a <=> b).to_i64)
  end

  @[Scheme::SchemeFn("bigdecimal=?", min: 2, max: 2)]
  def bigdecimal_eq(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(bigdecimal_arg(args[0], "bigdecimal=?") == bigdecimal_arg(args[1], "bigdecimal=?"))
  end

  @[Scheme::SchemeFn("bigdecimal<?", min: 2, max: 2)]
  def bigdecimal_lt(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(bigdecimal_arg(args[0], "bigdecimal<?") < bigdecimal_arg(args[1], "bigdecimal<?"))
  end

  @[Scheme::SchemeFn("bigdecimal>?", min: 2, max: 2)]
  def bigdecimal_gt(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(bigdecimal_arg(args[0], "bigdecimal>?") > bigdecimal_arg(args[1], "bigdecimal>?"))
  end

  @[Scheme::SchemeFn("bigdecimal-zero?", min: 1, max: 1)]
  def bigdecimal_zero_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(bigdecimal_arg(args[0], "bigdecimal-zero?").zero?)
  end

  @[Scheme::SchemeFn("bigdecimal->string", min: 1, max: 1)]
  def bigdecimal_to_string(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeStr.new(bigdecimal_arg(args[0], "bigdecimal->string").to_s)
  end

  @[Scheme::SchemeFn("bigdecimal?", min: 1, max: 1)]
  def bigdecimal_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(args[0].is_a?(SchemeBigDecimal))
  end

  private def bigdecimal_arg(v : SchemeValue, who : String) : BigDecimal
    raise SchemeRuntimeError.new("#{who}: expected bigdecimal, got #{v.write_string}") unless v.is_a?(SchemeBigDecimal)
    v.value
  end

  private def bigdecimal_str_arg(v : SchemeValue, who : String) : String
    case v
    when SchemeStr then v.value
    when SchemeInt then v.value.to_s
    else
      raise SchemeRuntimeError.new("#{who}: expected string, got #{v.write_string}")
    end
  end
end

module Scheme
  class Interpreter
    register_library ["creme", "builtin", "bigdecimal"], Scheme::Builtins::BigDecimalLibrary
  end
end
