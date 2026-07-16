# ===========================================================================
# env module: process environment variables (SRFI-98 naming where a direct
# equivalent exists — get/all; the mutators have no SRFI-98 precedent since
# that SRFI treats environment variables as read-only, so they follow its
# lexeme style pragmatically instead)
# ===========================================================================

module Scheme::Builtins::EnvVars
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("get-environment-variable", min: 1, max: 1)]
  def get_environment_variable(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    key = env_str_arg(args[0], "get-environment-variable")
    v = ENV[key]?
    v ? SchemeStr.new(v).as(SchemeValue) : FALSE.as(SchemeValue)
  end

  @[Scheme::SchemeFn("set-environment-variable!", min: 2, max: 2)]
  def set_environment_variable(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    key = env_str_arg(args[0], "set-environment-variable!")
    val = env_str_arg(args[1], "set-environment-variable!")
    ENV[key] = val
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("delete-environment-variable!", min: 1, max: 1)]
  def delete_environment_variable(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    ENV.delete(env_str_arg(args[0], "delete-environment-variable!"))
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("environment-variable-set?", min: 1, max: 1)]
  def environment_variable_set_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(ENV.has_key?(env_str_arg(args[0], "environment-variable-set?")))
  end

  @[Scheme::SchemeFn("get-environment-variables", min: 0, max: 0)]
  def get_environment_variables(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    pairs = [] of SchemeValue
    ENV.each { |k, v| pairs << Cons.new(SchemeStr.new(k), SchemeStr.new(v)) }
    Scheme.a_to_list(pairs)
  end

  private def env_str_arg(v : SchemeValue, who : String) : String
    raise SchemeRuntimeError.new("#{who}: expected string, got #{v.write_string}") unless v.is_a?(SchemeStr)
    v.value
  end
end

module Scheme
  class Interpreter
    register_library ["creme", "env"], Scheme::Builtins::EnvVars
  end
end
