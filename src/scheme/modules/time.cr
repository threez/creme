# ===========================================================================
# time module: Unix epoch seconds (UTC) as the sole time representation
# ===========================================================================

module Scheme
  class Interpreter
    private def install_time(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(SchemeValue) -> SchemeValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      reg.call("current-time", 0, 0, ->(_args : Array(SchemeValue)) : SchemeValue do
        SchemeFloat.new(Time.utc.to_unix_f)
      end)

      reg.call("time-year", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeInt.new(time_from_epoch(args[0], "time-year").year.to_i64) })
      reg.call("time-month", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeInt.new(time_from_epoch(args[0], "time-month").month.to_i64) })
      reg.call("time-day", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeInt.new(time_from_epoch(args[0], "time-day").day.to_i64) })
      reg.call("time-hour", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeInt.new(time_from_epoch(args[0], "time-hour").hour.to_i64) })
      reg.call("time-minute", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeInt.new(time_from_epoch(args[0], "time-minute").minute.to_i64) })
      reg.call("time-second", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeInt.new(time_from_epoch(args[0], "time-second").second.to_i64) })

      reg.call("time->string", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        t = time_from_epoch(args[0], "time->string")
        fmt = args[1]
        raise SchemeRuntimeError.new("time->string: expected string format, got #{fmt.write_string}") unless fmt.is_a?(SchemeStr)
        SchemeStr.new(t.to_s(fmt.value))
      end)

      reg.call("string->time", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        s = args[0]
        fmt = args[1]
        raise SchemeRuntimeError.new("string->time: expected string, got #{s.write_string}") unless s.is_a?(SchemeStr)
        raise SchemeRuntimeError.new("string->time: expected string format, got #{fmt.write_string}") unless fmt.is_a?(SchemeStr)
        begin
          SchemeFloat.new(Time.parse(s.value, fmt.value, Time::Location::UTC).to_unix_f)
        rescue ex : Time::Format::Error
          raise SchemeRuntimeError.new("string->time: #{ex.message}")
        end
      end)

      reg.call("time-add", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        epoch = Scheme.as_f64(args[0], "time-add")
        secs = Scheme.as_f64(args[1], "time-add")
        SchemeFloat.new(epoch + secs)
      end)

      reg.call("time-difference", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        a = Scheme.as_f64(args[0], "time-difference")
        b = Scheme.as_f64(args[1], "time-difference")
        SchemeFloat.new(a - b)
      end)
    end

    private def time_from_epoch(v : SchemeValue, who : String) : Time
      epoch = Scheme.as_f64(v, who)
      Time.unix_ms((epoch * 1000).to_i64).to_utc
    end
  end
end
