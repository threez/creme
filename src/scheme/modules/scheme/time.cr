# ===========================================================================
# (scheme time)
# ===========================================================================
#
# Rebuilt here (not just wrapped) to match R7RS's actual contract:
# current-second/current-jiffy/jiffies-per-second. The existing rich
# epoch/format time API (current-time, time-year, time->string, ...) is
# untouched and lives as (creme time), a superset, not a replacement.

module Scheme::Builtins::SchemeTime
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("current-second", min: 0, max: 0)]
  def current_second(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeFloat.new(Time.utc.to_unix_f)
  end

  @[Scheme::SchemeFn("current-jiffy", min: 0, max: 0)]
  def current_jiffy(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeInt.new((Time.instant - interp.start_instant).total_microseconds.to_i64)
  end

  @[Scheme::SchemeFn("jiffies-per-second", min: 0, max: 0)]
  def jiffies_per_second(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeInt.new(1_000_000_i64)
  end
end

module Scheme
  class Interpreter
    register_library ["creme", "builtin", "scheme-time"], Scheme::Builtins::SchemeTime
  end
end
