# ===========================================================================
# (scheme process-context)
# ===========================================================================
#
# (scheme process-context) owns exit / emergency-exit (below) and reuses the
# R7RS-standard subsets of two richer creme modules: command-line from
# Scheme::Builtins::ProcessLibrary (modules/creme/process.cr) and
# get-environment-variable/get-environment-variables from
# Scheme::Builtins::EnvVars (modules/creme/env.cr). Every export is derived
# from a register_module return, so there is no hand-maintained subset list.

module Scheme::Builtins::ProcessContext
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("exit", min: 0, max: 1)]
  def exit(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    code = args.empty? ? 0 : int_arg(args[0], "exit").clamp(0_i64, 255_i64).to_i
    raise SchemeExit.new(code)
  end

  # emergency-exit terminates without running dynamic-wind after-thunks or
  # outstanding cleanup; this implementation unwinds via the same
  # SchemeExit that main.cr turns into a process exit, so it behaves like
  # exit for the embedding contract's purposes.
  @[Scheme::SchemeFn("emergency-exit", min: 0, max: 1)]
  def emergency_exit(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    code = args.empty? ? 0 : int_arg(args[0], "emergency-exit").clamp(0_i64, 255_i64).to_i
    raise SchemeExit.new(code)
  end
end

module Scheme
  class Interpreter
    register_library ["scheme", "process-context"] do |env|
      register_module(Scheme::Builtins::ProcessLibrary, env) +
        register_module(Scheme::Builtins::EnvVars, env) +
        register_module(Scheme::Builtins::ProcessContext, env)
    end
  end
end
