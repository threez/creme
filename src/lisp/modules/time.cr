# ===========================================================================
# time module: Unix epoch seconds (UTC) as the sole time representation
# ===========================================================================

module LISP
  class Interpreter
    private def install_time(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(LispValue) -> LispValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      reg.call("now", 0, 0, ->(_args : Array(LispValue)) : LispValue do
        LispFloat.new(Time.utc.to_unix_f)
      end)

      reg.call("year", 1, 1, ->(args : Array(LispValue)) : LispValue { LispInt.new(time_from_epoch(args[0], "time:year").year.to_i64) })
      reg.call("month", 1, 1, ->(args : Array(LispValue)) : LispValue { LispInt.new(time_from_epoch(args[0], "time:month").month.to_i64) })
      reg.call("day", 1, 1, ->(args : Array(LispValue)) : LispValue { LispInt.new(time_from_epoch(args[0], "time:day").day.to_i64) })
      reg.call("hour", 1, 1, ->(args : Array(LispValue)) : LispValue { LispInt.new(time_from_epoch(args[0], "time:hour").hour.to_i64) })
      reg.call("minute", 1, 1, ->(args : Array(LispValue)) : LispValue { LispInt.new(time_from_epoch(args[0], "time:minute").minute.to_i64) })
      reg.call("second", 1, 1, ->(args : Array(LispValue)) : LispValue { LispInt.new(time_from_epoch(args[0], "time:second").second.to_i64) })

      reg.call("format", 2, 2, ->(args : Array(LispValue)) : LispValue do
        t = time_from_epoch(args[0], "time:format")
        fmt = args[1]
        raise LispRuntimeError.new("time:format: expected string format, got #{fmt.write_string}") unless fmt.is_a?(LispStr)
        LispStr.new(t.to_s(fmt.value))
      end)

      reg.call("parse", 2, 2, ->(args : Array(LispValue)) : LispValue do
        s = args[0]
        fmt = args[1]
        raise LispRuntimeError.new("time:parse: expected string, got #{s.write_string}") unless s.is_a?(LispStr)
        raise LispRuntimeError.new("time:parse: expected string format, got #{fmt.write_string}") unless fmt.is_a?(LispStr)
        begin
          LispFloat.new(Time.parse(s.value, fmt.value, Time::Location::UTC).to_unix_f)
        rescue ex : Time::Format::Error
          raise LispRuntimeError.new("time:parse: #{ex.message}")
        end
      end)

      reg.call("add-seconds", 2, 2, ->(args : Array(LispValue)) : LispValue do
        epoch = LISP.as_f64(args[0], "time:add-seconds")
        secs = LISP.as_f64(args[1], "time:add-seconds")
        LispFloat.new(epoch + secs)
      end)

      reg.call("diff", 2, 2, ->(args : Array(LispValue)) : LispValue do
        a = LISP.as_f64(args[0], "time:diff")
        b = LISP.as_f64(args[1], "time:diff")
        LispFloat.new(a - b)
      end)
    end

    private def time_from_epoch(v : LispValue, who : String) : Time
      epoch = LISP.as_f64(v, who)
      Time.unix_ms((epoch * 1000).to_i64).to_utc
    end
  end
end
