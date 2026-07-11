# ===========================================================================
# math module: transcendental functions and constants
# ===========================================================================

module LISP
  class Interpreter
    private def install_math(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(LispValue) -> LispValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      unary = ->(who : String, f : Float64 -> Float64) do
        Builtin.new(who, 1, 1) do |args|
          LispFloat.new(f.call(LISP.as_f64(args[0], who))).as(LispValue)
        end
      end

      env.define("sin", unary.call("math:sin", ->(x : Float64) { Math.sin(x) }))
      env.define("cos", unary.call("math:cos", ->(x : Float64) { Math.cos(x) }))
      env.define("tan", unary.call("math:tan", ->(x : Float64) { Math.tan(x) }))
      env.define("asin", unary.call("math:asin", ->(x : Float64) { Math.asin(x) }))
      env.define("acos", unary.call("math:acos", ->(x : Float64) { Math.acos(x) }))
      env.define("atan", unary.call("math:atan", ->(x : Float64) { Math.atan(x) }))
      env.define("log", unary.call("math:log", ->(x : Float64) { Math.log(x) }))
      env.define("log2", unary.call("math:log2", ->(x : Float64) { Math.log2(x) }))
      env.define("log10", unary.call("math:log10", ->(x : Float64) { Math.log10(x) }))
      env.define("exp", unary.call("math:exp", ->(x : Float64) { Math.exp(x) }))
      env.define("floor", unary.call("math:floor", ->(x : Float64) { x.floor }))
      env.define("ceil", unary.call("math:ceil", ->(x : Float64) { x.ceil }))
      env.define("round", unary.call("math:round", ->(x : Float64) { x.round }))
      env.define("truncate", unary.call("math:truncate", ->(x : Float64) { x.trunc }))

      reg.call("atan2", 2, 2, ->(args : Array(LispValue)) : LispValue do
        LispFloat.new(Math.atan2(LISP.as_f64(args[0], "math:atan2"), LISP.as_f64(args[1], "math:atan2")))
      end)

      reg.call("pow", 2, 2, ->(args : Array(LispValue)) : LispValue do
        LispFloat.new(LISP.as_f64(args[0], "math:pow") ** LISP.as_f64(args[1], "math:pow"))
      end)

      reg.call("hypot", 2, 2, ->(args : Array(LispValue)) : LispValue do
        LispFloat.new(Math.hypot(LISP.as_f64(args[0], "math:hypot"), LISP.as_f64(args[1], "math:hypot")))
      end)

      env.define("pi", LispFloat.new(Math::PI))
      env.define("e", LispFloat.new(Math::E))
    end
  end
end
