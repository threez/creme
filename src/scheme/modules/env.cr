# ===========================================================================
# env module: process environment variables (SRFI-98 naming where a direct
# equivalent exists — get/all; the mutators have no SRFI-98 precedent since
# that SRFI treats environment variables as read-only, so they follow its
# lexeme style pragmatically instead)
# ===========================================================================

module Scheme
  class Interpreter
    private def install_env(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(SchemeValue) -> SchemeValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      reg.call("get-environment-variable", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        key = env_str_arg(args[0], "get-environment-variable")
        v = ENV[key]?
        v ? SchemeStr.new(v).as(SchemeValue) : FALSE.as(SchemeValue)
      end)

      reg.call("set-environment-variable!", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        key = env_str_arg(args[0], "set-environment-variable!")
        val = env_str_arg(args[1], "set-environment-variable!")
        ENV[key] = val
        NIL.as(SchemeValue)
      end)

      reg.call("delete-environment-variable!", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        ENV.delete(env_str_arg(args[0], "delete-environment-variable!"))
        NIL.as(SchemeValue)
      end)

      reg.call("environment-variable-set?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        SchemeBool.of(ENV.has_key?(env_str_arg(args[0], "environment-variable-set?")))
      end)

      reg.call("get-environment-variables", 0, 0, ->(_args : Array(SchemeValue)) : SchemeValue do
        pairs = [] of SchemeValue
        ENV.each { |k, v| pairs << Cons.new(SchemeStr.new(k), SchemeStr.new(v)) }
        Scheme.a_to_list(pairs)
      end)
    end

    private def env_str_arg(v : SchemeValue, who : String) : String
      raise SchemeRuntimeError.new("#{who}: expected string, got #{v.write_string}") unless v.is_a?(SchemeStr)
      v.value
    end
  end
end
