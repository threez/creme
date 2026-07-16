# ===========================================================================
# (scheme lazy)
# ===========================================================================

module Scheme
  class Interpreter
    SCHEME_LAZY_EXPORTS = %w[delay delay-force force make-promise promise?]

    register_library ["scheme", "lazy"] do |env|
      SCHEME_LAZY_EXPORTS.each { |name| env.define(name, name == "delay" || name == "delay-force" ? SchemeSpecialForm.new(name) : @base_env.get(name)) }
      SCHEME_LAZY_EXPORTS
    end
  end
end
