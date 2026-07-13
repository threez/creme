# ===========================================================================
# random module: random numbers, choices, shuffling (SRFI-27 naming where
# a direct equivalent exists: random-real is exactly SRFI-27's
# (random-real), and random-integer matches SRFI-27's exact single-bound,
# zero-based, exclusive-upper-bound (random-integer n) -> [0, n) contract —
# not this module's old two-arg inclusive-range signature).
# ===========================================================================

module Scheme
  class Interpreter
    private def install_random(env : Env) : Nil
      rng = Random.new

      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(SchemeValue) -> SchemeValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      reg.call("random-real", 0, 0, ->(_args : Array(SchemeValue)) : SchemeValue do
        SchemeFloat.new(rng.rand)
      end)

      reg.call("random-integer", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        n = random_int_arg(args[0], "random-integer")
        raise SchemeRuntimeError.new("random-integer: n must be positive") if n <= 0
        SchemeInt.new(rng.rand(n))
      end)

      reg.call("random-seed!", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        seed = random_int_arg(args[0], "random-seed!")
        rng = Random.new(seed.to_u64)
        NIL.as(SchemeValue)
      end)

      reg.call("random-choice", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        elems = Scheme.list_to_a(args[0])
        raise SchemeRuntimeError.new("random-choice: expects a non-empty list") if elems.empty?
        elems.sample(random: rng)
      end)

      reg.call("random-shuffle", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        elems = Scheme.list_to_a(args[0])
        Scheme.a_to_list(elems.shuffle(random: rng))
      end)
    end

    private def random_int_arg(v : SchemeValue, who : String) : Int64
      raise SchemeRuntimeError.new("#{who}: expected integer, got #{v.write_string}") unless v.is_a?(SchemeInt)
      v.value
    end
  end
end
