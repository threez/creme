# ===========================================================================
# (scheme read)
# ===========================================================================

module Scheme
  class Interpreter
    SCHEME_READ_EXPORTS = %w[read]

    register_library ["scheme", "read"] do |env|
      env.define("read", @base_env.get("read"))
      SCHEME_READ_EXPORTS
    end
  end
end
