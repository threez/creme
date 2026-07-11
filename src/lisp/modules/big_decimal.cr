# ===========================================================================
# bigdecimal module: arbitrary-precision decimal arithmetic
# ===========================================================================

require "big"

module LISP
  class LispBigDecimal < LispValue
    getter value : BigDecimal

    def initialize(@value : BigDecimal)
    end

    def to_display(io : IO) : Nil
      io << @value
    end
  end

  class Interpreter
    private def install_bigdecimal(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(LispValue) -> LispValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      reg.call("parse", 1, 1, ->(args : Array(LispValue)) : LispValue do
        s = bigdecimal_str_arg(args[0], "bigdecimal:parse")
        begin
          LispBigDecimal.new(BigDecimal.new(s))
        rescue ex : Exception
          raise LispRuntimeError.new("bigdecimal:parse: invalid decimal '#{s}'")
        end
      end)

      reg.call("from-int", 1, 1, ->(args : Array(LispValue)) : LispValue do
        n = args[0]
        raise LispRuntimeError.new("bigdecimal:from-int: expected integer, got #{n.write_string}") unless n.is_a?(LispInt)
        LispBigDecimal.new(BigDecimal.new(n.value))
      end)

      reg.call("add", 2, 2, ->(args : Array(LispValue)) : LispValue do
        a = bigdecimal_arg(args[0], "bigdecimal:add")
        b = bigdecimal_arg(args[1], "bigdecimal:add")
        LispBigDecimal.new(a + b)
      end)

      reg.call("sub", 2, 2, ->(args : Array(LispValue)) : LispValue do
        a = bigdecimal_arg(args[0], "bigdecimal:sub")
        b = bigdecimal_arg(args[1], "bigdecimal:sub")
        LispBigDecimal.new(a - b)
      end)

      reg.call("mul", 2, 2, ->(args : Array(LispValue)) : LispValue do
        a = bigdecimal_arg(args[0], "bigdecimal:mul")
        b = bigdecimal_arg(args[1], "bigdecimal:mul")
        LispBigDecimal.new(a * b)
      end)

      reg.call("div", 2, 2, ->(args : Array(LispValue)) : LispValue do
        a = bigdecimal_arg(args[0], "bigdecimal:div")
        b = bigdecimal_arg(args[1], "bigdecimal:div")
        raise LispRuntimeError.new("bigdecimal:div: division by zero") if b.zero?
        LispBigDecimal.new(a / b)
      end)

      reg.call("neg", 1, 1, ->(args : Array(LispValue)) : LispValue do
        LispBigDecimal.new(-bigdecimal_arg(args[0], "bigdecimal:neg"))
      end)

      reg.call("compare", 2, 2, ->(args : Array(LispValue)) : LispValue do
        a = bigdecimal_arg(args[0], "bigdecimal:compare")
        b = bigdecimal_arg(args[1], "bigdecimal:compare")
        LispInt.new((a <=> b).to_i64)
      end)

      reg.call("=", 2, 2, ->(args : Array(LispValue)) : LispValue do
        LispBool.of(bigdecimal_arg(args[0], "bigdecimal:=") == bigdecimal_arg(args[1], "bigdecimal:="))
      end)

      reg.call("<", 2, 2, ->(args : Array(LispValue)) : LispValue do
        LispBool.of(bigdecimal_arg(args[0], "bigdecimal:<") < bigdecimal_arg(args[1], "bigdecimal:<"))
      end)

      reg.call(">", 2, 2, ->(args : Array(LispValue)) : LispValue do
        LispBool.of(bigdecimal_arg(args[0], "bigdecimal:>") > bigdecimal_arg(args[1], "bigdecimal:>"))
      end)

      reg.call("zero?", 1, 1, ->(args : Array(LispValue)) : LispValue do
        LispBool.of(bigdecimal_arg(args[0], "bigdecimal:zero?").zero?)
      end)

      reg.call("to-string", 1, 1, ->(args : Array(LispValue)) : LispValue do
        LispStr.new(bigdecimal_arg(args[0], "bigdecimal:to-string").to_s)
      end)

      reg.call("bigdecimal?", 1, 1, ->(args : Array(LispValue)) : LispValue do
        LispBool.of(args[0].is_a?(LispBigDecimal))
      end)
    end

    private def bigdecimal_arg(v : LispValue, who : String) : BigDecimal
      raise LispRuntimeError.new("#{who}: expected bigdecimal, got #{v.write_string}") unless v.is_a?(LispBigDecimal)
      v.value
    end

    private def bigdecimal_str_arg(v : LispValue, who : String) : String
      case v
      when LispStr then v.value
      when LispInt then v.value.to_s
      else
        raise LispRuntimeError.new("#{who}: expected string, got #{v.write_string}")
      end
    end
  end
end
