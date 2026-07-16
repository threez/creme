# ===========================================================================
# (scheme repl)
# ===========================================================================

module Scheme
  class Interpreter
    SCHEME_REPL_EXPORTS = %w[interaction-environment]

    register_library ["scheme", "repl"] do |env|
      SCHEME_REPL_EXPORTS.each { |name| env.define(name, @base_env.get(name)) }
      SCHEME_REPL_EXPORTS
    end
  end
end
