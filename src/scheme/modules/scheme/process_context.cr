# ===========================================================================
# (scheme process-context)
# ===========================================================================

module Scheme
  class Interpreter
    # register_module(ProcessLibrary/EnvVars, ...) install their own full
    # (creme process)/(creme env) surfaces into env — (scheme process-context)
    # only EXPORTS the R7RS subset below (e.g. not process-run,
    # set-environment-variable!, ...), so this can't be derived from their
    # return values the way most other libraries' exports are.
    SCHEME_PROCESS_CONTEXT_EXPORTS = %w[command-line emergency-exit exit get-environment-variable get-environment-variables]

    register_library ["scheme", "process-context"] do |env|
      register_module(Scheme::Builtins::ProcessLibrary, env)
      register_module(Scheme::Builtins::EnvVars, env)
      env.define("exit", @base_env.get("exit"))
      env.define("emergency-exit", @base_env.get("exit"))
      SCHEME_PROCESS_CONTEXT_EXPORTS
    end
  end
end
