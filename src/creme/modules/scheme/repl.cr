# ===========================================================================
# (scheme repl)
# ===========================================================================

module Creme::R7RS::ReplLibrary
  extend self
  include Creme::BuiltinHelpers

  # (interaction-environment) — a specifier for the environment a REPL
  # would evaluate typed-in expressions against, i.e. @global itself.
  # `interp` is stale for an actor Fiber (captured at registration time,
  # always the root Interpreter — see builtin_registration.cr), so resolve
  # the Interpreter actually running THIS fiber instead: otherwise an actor
  # would get a specifier for the ROOT's @global rather than its own.
  @[Creme::SchemeFn("interaction-environment", min: 0, max: 0)]
  def interaction_environment(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeEnvironment.new((Interpreter.current || interp).global)
  end
end

module Creme
  class Interpreter
    register_library ["creme", "builtin", "repl"], Creme::R7RS::ReplLibrary
  end
end
