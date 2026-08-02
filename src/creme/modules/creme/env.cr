# ===========================================================================
# env module: process environment variables (SRFI-98 naming where a direct
# equivalent exists — get/all; the mutators have no SRFI-98 precedent since
# that SRFI treats environment variables as read-only, so they follow its
# lexeme style pragmatically instead)
# ===========================================================================
#
# EnvVars holds the two read-only accessors R7RS's (scheme process-context)
# specifies (get-environment-variable / get-environment-variables) — so
# (scheme process-context) (modules/scheme/process_context.cr) registers it
# directly and derives its exports. EnvExtra holds the creme-only mutators;
# (creme env) registers BOTH.

module Creme::Builtins::EnvVars
  extend self
  include Creme::BuiltinHelpers

  @[Creme::SchemeFn("get-environment-variable", min: 1, max: 1)]
  def get_environment_variable(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    key = env_str_arg(args[0], "get-environment-variable")
    v = ENV[key]?
    v ? SchemeStr.new(v).as(SchemeValue) : FALSE.as(SchemeValue)
  end

  @[Creme::SchemeFn("get-environment-variables", min: 0, max: 0)]
  def get_environment_variables(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    pairs = [] of SchemeValue
    ENV.each { |k, v| pairs << Cons.new(SchemeStr.new(k), SchemeStr.new(v)) }
    Creme.a_to_list(pairs)
  end

  private def env_str_arg(v : SchemeValue, who : String) : String
    raise SchemeRuntimeError.new("#{who}: expected string, got #{v.write_string}") unless v.is_a?(SchemeStr)
    v.value
  end
end

# creme-only environment mutators, beyond R7RS's read-only contract.
module Creme::Builtins::EnvExtra
  extend self
  include Creme::BuiltinHelpers

  @[Creme::SchemeFn("set-environment-variable!", min: 2, max: 2)]
  def set_environment_variable(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    key = env_str_arg(args[0], "set-environment-variable!")
    val = env_str_arg(args[1], "set-environment-variable!")
    ENV[key] = val
    NIL.as(SchemeValue)
  end

  @[Creme::SchemeFn("delete-environment-variable!", min: 1, max: 1)]
  def delete_environment_variable(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    ENV.delete(env_str_arg(args[0], "delete-environment-variable!"))
    NIL.as(SchemeValue)
  end

  @[Creme::SchemeFn("environment-variable-set?", min: 1, max: 1)]
  def environment_variable_set_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(ENV.has_key?(env_str_arg(args[0], "environment-variable-set?")))
  end

  private def env_str_arg(v : SchemeValue, who : String) : String
    raise SchemeRuntimeError.new("#{who}: expected string, got #{v.write_string}") unless v.is_a?(SchemeStr)
    v.value
  end
end

module Creme
  class Interpreter
    register_library ["creme", "builtin", "env"] do |env|
      register_module(Creme::Builtins::EnvVars, env) +
        register_module(Creme::Builtins::EnvExtra, env)
    end
  end
end
