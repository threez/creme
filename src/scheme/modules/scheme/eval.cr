# ===========================================================================
# (scheme eval)
# ===========================================================================

module Scheme
  class Interpreter
    SCHEME_EVAL_EXPORTS = %w[environment eval]

    register_library ["scheme", "eval"] do |env|
      SCHEME_EVAL_EXPORTS.each { |name| env.define(name, @base_env.get(name)) }
      SCHEME_EVAL_EXPORTS
    end
  end
end
