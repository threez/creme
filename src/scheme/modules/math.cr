# ===========================================================================
# math module: transcendental functions and constants
# ===========================================================================

module Scheme
  class Interpreter
    private def install_math(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(SchemeValue) -> SchemeValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      unary = ->(who : String, f : Float64 -> Float64) do
        Builtin.new(who, 1, 1) do |args|
          SchemeFloat.new(f.call(Scheme.as_f64(args[0], who))).as(SchemeValue)
        end
      end

      env.define("sin", unary.call("sin", ->(x : Float64) { Math.sin(x) }))
      env.define("cos", unary.call("cos", ->(x : Float64) { Math.cos(x) }))
      env.define("tan", unary.call("tan", ->(x : Float64) { Math.tan(x) }))
      env.define("asin", unary.call("asin", ->(x : Float64) { Math.asin(x) }))
      env.define("acos", unary.call("acos", ->(x : Float64) { Math.acos(x) }))
      env.define("atan", unary.call("atan", ->(x : Float64) { Math.atan(x) }))
      reg.call("log", 1, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        x = Scheme.as_f64(args[0], "log")
        if args.size == 2
          SchemeFloat.new(Math.log(x) / Math.log(Scheme.as_f64(args[1], "log")))
        else
          SchemeFloat.new(Math.log(x))
        end
      end)
      env.define("log2", unary.call("log2", ->(x : Float64) { Math.log2(x) }))
      env.define("log10", unary.call("log10", ->(x : Float64) { Math.log10(x) }))
      env.define("exp", unary.call("exp", ->(x : Float64) { Math.exp(x) }))

      reg.call("atan2", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        SchemeFloat.new(Math.atan2(Scheme.as_f64(args[0], "atan2"), Scheme.as_f64(args[1], "atan2")))
      end)

      reg.call("pow", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        SchemeFloat.new(Scheme.as_f64(args[0], "pow") ** Scheme.as_f64(args[1], "pow"))
      end)

      reg.call("hypot", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        SchemeFloat.new(Math.hypot(Scheme.as_f64(args[0], "hypot"), Scheme.as_f64(args[1], "hypot")))
      end)

      env.define("pi", SchemeFloat.new(Math::PI))
      env.define("e", SchemeFloat.new(Math::E))
    end
  end
end
