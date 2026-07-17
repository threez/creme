# ===========================================================================
# (scheme case-lambda)
# ===========================================================================
#
# case-lambda is a special form recognized by the analyzer — bound in
# @base_env as a SchemeSpecialForm marker (install_special_forms) — so it's
# borrowed rather than being an annotatable method.

module Scheme
  class Interpreter
    register_library ["scheme", "case-lambda"] do |env|
      names = %w[case-lambda]
      names.each { |name| env.define(name, @base_env.get(name)) }
      names
    end
  end
end
