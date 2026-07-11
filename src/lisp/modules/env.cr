# ===========================================================================
# env module: process environment variables
# ===========================================================================

module LISP
  class Interpreter
    private def install_env(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(LispValue) -> LispValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      reg.call("get", 1, 1, ->(args : Array(LispValue)) : LispValue do
        key = env_str_arg(args[0], "env:get")
        v = ENV[key]?
        v ? LispStr.new(v).as(LispValue) : FALSE.as(LispValue)
      end)

      reg.call("set!", 2, 2, ->(args : Array(LispValue)) : LispValue do
        key = env_str_arg(args[0], "env:set!")
        val = env_str_arg(args[1], "env:set!")
        ENV[key] = val
        NIL.as(LispValue)
      end)

      reg.call("delete!", 1, 1, ->(args : Array(LispValue)) : LispValue do
        ENV.delete(env_str_arg(args[0], "env:delete!"))
        NIL.as(LispValue)
      end)

      reg.call("has?", 1, 1, ->(args : Array(LispValue)) : LispValue do
        LispBool.of(ENV.has_key?(env_str_arg(args[0], "env:has?")))
      end)

      reg.call("all", 0, 0, ->(_args : Array(LispValue)) : LispValue do
        pairs = [] of LispValue
        ENV.each { |k, v| pairs << Cons.new(LispStr.new(k), LispStr.new(v)) }
        LISP.a_to_list(pairs)
      end)
    end

    private def env_str_arg(v : LispValue, who : String) : String
      raise LispRuntimeError.new("#{who}: expected string, got #{v.write_string}") unless v.is_a?(LispStr)
      v.value
    end
  end
end
