# ===========================================================================
# (scheme case-lambda)
# ===========================================================================

module Scheme
  class Interpreter
    SCHEME_CASE_LAMBDA_EXPORTS = %w[case-lambda]

    register_library ["scheme", "case-lambda"] do |env|
      env.define("case-lambda", @base_env.get("case-lambda"))
      SCHEME_CASE_LAMBDA_EXPORTS
    end
  end
end
