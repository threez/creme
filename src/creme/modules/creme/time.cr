# ===========================================================================
# time module: Unix epoch seconds (UTC) as the sole time representation
# ===========================================================================

module Creme::Builtins::TimeLibrary
  extend self
  include Creme::BuiltinHelpers

  @[Creme::SchemeFn("current-time", min: 0, max: 0)]
  def current_time(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeFloat.new(Time.utc.to_unix_f)
  end

  @[Creme::SchemeFn("time-year", min: 1, max: 1)]
  def time_year(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeInt.new(time_from_epoch(args[0], "time-year").year.to_i64)
  end

  @[Creme::SchemeFn("time-month", min: 1, max: 1)]
  def time_month(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeInt.new(time_from_epoch(args[0], "time-month").month.to_i64)
  end

  @[Creme::SchemeFn("time-day", min: 1, max: 1)]
  def time_day(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeInt.new(time_from_epoch(args[0], "time-day").day.to_i64)
  end

  @[Creme::SchemeFn("time-hour", min: 1, max: 1)]
  def time_hour(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeInt.new(time_from_epoch(args[0], "time-hour").hour.to_i64)
  end

  @[Creme::SchemeFn("time-minute", min: 1, max: 1)]
  def time_minute(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeInt.new(time_from_epoch(args[0], "time-minute").minute.to_i64)
  end

  @[Creme::SchemeFn("time-second", min: 1, max: 1)]
  def time_second(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeInt.new(time_from_epoch(args[0], "time-second").second.to_i64)
  end

  @[Creme::SchemeFn("time->string", min: 2, max: 2)]
  def time_to_string(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    t = time_from_epoch(args[0], "time->string")
    fmt = args[1]
    raise SchemeRuntimeError.new("time->string: expected string format, got #{fmt.write_string}") unless fmt.is_a?(SchemeStr)
    SchemeStr.new(t.to_s(fmt.value))
  end

  @[Creme::SchemeFn("string->time", min: 2, max: 2)]
  def string_to_time(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    s = args[0]
    fmt = args[1]
    raise SchemeRuntimeError.new("string->time: expected string, got #{s.write_string}") unless s.is_a?(SchemeStr)
    raise SchemeRuntimeError.new("string->time: expected string format, got #{fmt.write_string}") unless fmt.is_a?(SchemeStr)
    SchemeFloat.new(Time.parse(s.value, fmt.value, Time::Location::UTC).to_unix_f)
  rescue ex : Time::Format::Error
    raise SchemeRuntimeError.new("string->time: #{ex.message}")
  end

  @[Creme::SchemeFn("time-add", min: 2, max: 2)]
  def time_add(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    epoch = Creme.as_f64(args[0], "time-add")
    secs = Creme.as_f64(args[1], "time-add")
    SchemeFloat.new(epoch + secs)
  end

  @[Creme::SchemeFn("time-difference", min: 2, max: 2)]
  def time_difference(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    a = Creme.as_f64(args[0], "time-difference")
    b = Creme.as_f64(args[1], "time-difference")
    SchemeFloat.new(a - b)
  end

  private def time_from_epoch(v : SchemeValue, who : String) : Time
    epoch = Creme.as_f64(v, who)
    Time.unix_ms((epoch * 1000).to_i64).to_utc
  end
end

module Creme
  class Interpreter
    register_library ["creme", "builtin", "time"], Creme::Builtins::TimeLibrary
  end
end
