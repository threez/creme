# ===========================================================================
# (scheme r5rs)
# ===========================================================================

module Scheme
  class Interpreter
    SCHEME_R5RS_EXPORTS = SCHEME_BASE_EXPORTS + %w[null-environment scheme-report-environment]

    register_library ["scheme", "r5rs"] do |env|
      SCHEME_R5RS_EXPORTS.each { |name| env.define(name, @base_env.get(name)) }
      SCHEME_R5RS_EXPORTS
    end
  end
end
