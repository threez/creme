# ===========================================================================
# (scheme eval)
# ===========================================================================

module Creme::R7RS::EvalLibrary
  extend self
  include Creme::BuiltinHelpers

  # `interp` is captured once at registration time (always the root
  # Interpreter — see builtin_registration.cr) and so is stale for any actor
  # Fiber (see (creme actor)/interpreter.cr#apply's own `active` comment);
  # resolve the Interpreter actually running THIS fiber instead, so a
  # default-target eval from inside an actor lands in that actor's own
  # private @global, not the root's.
  @[Creme::SchemeFn("eval", min: 1, max: 2)]
  def eval(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    active = Interpreter.current || interp
    target_env = args.size == 2 ? environment_specifier_arg(args[1], "eval") : active.global
    # Eval'd data has no enclosing lexical frame -> analyze with an empty scope.
    BytecodeCompiler.run_program(active, [args[0]], target_env)
  end

  # (environment list...) — a fresh, otherwise-empty Env populated by
  # importing each list as an import set (the same grammar/mechanism
  # eval_import uses for a program's own top-level import declarations).
  # The resulting environment specifier's bindings are immutable in the
  # sense that R7RS describes (this implementation doesn't separately
  # enforce that; nothing here differs from any other Env in practice).
  @[Creme::SchemeFn("environment", min: 0, max: -1)]
  def environment(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    active = Interpreter.current || interp
    target_env = Env.new
    args.each { |import_set| active.import_into(target_env, import_set) }
    SchemeEnvironment.new(target_env)
  end
end

module Creme
  class Interpreter
    register_library ["creme", "builtin", "eval"], Creme::R7RS::EvalLibrary
  end
end
