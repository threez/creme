# ===========================================================================
# bigdecimal module: arbitrary-precision decimal arithmetic
# ===========================================================================

require "big"

module Scheme
  class SchemeBigDecimal < SchemeValue
    getter value : BigDecimal

    def initialize(@value : BigDecimal)
    end

    def to_display(io : IO) : Nil
      io << @value
    end
  end

  class Interpreter
    private def install_bigdecimal(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(SchemeValue) -> SchemeValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      reg.call("string->bigdecimal", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        s = bigdecimal_str_arg(args[0], "string->bigdecimal")
        begin
          SchemeBigDecimal.new(BigDecimal.new(s))
        rescue ex : Exception
          raise SchemeRuntimeError.new("string->bigdecimal: invalid decimal '#{s}'")
        end
      end)

      reg.call("integer->bigdecimal", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        n = args[0]
        raise SchemeRuntimeError.new("integer->bigdecimal: expected integer, got #{n.write_string}") unless n.is_a?(SchemeInt)
        SchemeBigDecimal.new(BigDecimal.new(n.value))
      end)

      reg.call("bigdecimal-add", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        a = bigdecimal_arg(args[0], "bigdecimal-add")
        b = bigdecimal_arg(args[1], "bigdecimal-add")
        SchemeBigDecimal.new(a + b)
      end)

      reg.call("bigdecimal-sub", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        a = bigdecimal_arg(args[0], "bigdecimal-sub")
        b = bigdecimal_arg(args[1], "bigdecimal-sub")
        SchemeBigDecimal.new(a - b)
      end)

      reg.call("bigdecimal-mul", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        a = bigdecimal_arg(args[0], "bigdecimal-mul")
        b = bigdecimal_arg(args[1], "bigdecimal-mul")
        SchemeBigDecimal.new(a * b)
      end)

      reg.call("bigdecimal-div", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        a = bigdecimal_arg(args[0], "bigdecimal-div")
        b = bigdecimal_arg(args[1], "bigdecimal-div")
        raise SchemeRuntimeError.new("bigdecimal-div: division by zero") if b.zero?
        SchemeBigDecimal.new(a / b)
      end)

      reg.call("bigdecimal-neg", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        SchemeBigDecimal.new(-bigdecimal_arg(args[0], "bigdecimal-neg"))
      end)

      reg.call("bigdecimal-compare", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        a = bigdecimal_arg(args[0], "bigdecimal-compare")
        b = bigdecimal_arg(args[1], "bigdecimal-compare")
        SchemeInt.new((a <=> b).to_i64)
      end)

      reg.call("bigdecimal=?", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        SchemeBool.of(bigdecimal_arg(args[0], "bigdecimal=?") == bigdecimal_arg(args[1], "bigdecimal=?"))
      end)

      reg.call("bigdecimal<?", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        SchemeBool.of(bigdecimal_arg(args[0], "bigdecimal<?") < bigdecimal_arg(args[1], "bigdecimal<?"))
      end)

      reg.call("bigdecimal>?", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        SchemeBool.of(bigdecimal_arg(args[0], "bigdecimal>?") > bigdecimal_arg(args[1], "bigdecimal>?"))
      end)

      reg.call("bigdecimal-zero?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        SchemeBool.of(bigdecimal_arg(args[0], "bigdecimal-zero?").zero?)
      end)

      reg.call("bigdecimal->string", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        SchemeStr.new(bigdecimal_arg(args[0], "bigdecimal->string").to_s)
      end)

      reg.call("bigdecimal?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        SchemeBool.of(args[0].is_a?(SchemeBigDecimal))
      end)
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
end
