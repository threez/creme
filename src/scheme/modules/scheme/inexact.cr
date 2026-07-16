# ===========================================================================
# (scheme inexact)
# ===========================================================================
#
# The trig/log functions are Crystal-native and only otherwise reachable via
# the non-standard (creme math); sqrt/finite?/infinite?/nan? are already
# core (scheme base) builtins, so this library's Env borrows those from
# @base_env by copy (not a chain) — each SchemeLibrary Env is independent
# per the design decision in library.cr, so a direct binding copy (not
# import_bindings, which would be circular here since @base_env isn't
# itself a SchemeLibrary export source for non-base names) is simplest.

module Scheme
  class Interpreter
    # register_module(MathLibrary, ...) installs (creme math)'s full, richer
    # surface (including log2/log10/atan2/pow/hypot/pi/e) — (scheme inexact)
    # only EXPORTS the R7RS subset below, a deliberate subset of what's
    # actually bound in this library's env, so this can't be derived from
    # that call's own return value the way most other libraries' exports are.
    SCHEME_INEXACT_EXPORTS = %w[acos asin atan cos exp finite? infinite? log nan? sin sqrt tan]

    register_library ["scheme", "inexact"] do |env|
      register_module(Scheme::Builtins::MathLibrary, env)
      %w[sqrt finite? infinite? nan?].each { |name| env.define(name, @base_env.get(name)) }
      SCHEME_INEXACT_EXPORTS
    end
  end
end
