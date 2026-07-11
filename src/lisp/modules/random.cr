# ===========================================================================
# random module: random numbers, choices, shuffling
# ===========================================================================

module LISP
  class Interpreter
    private def install_random(env : Env) : Nil
      rng = Random.new

      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(LispValue) -> LispValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      reg.call("float", 0, 0, ->(_args : Array(LispValue)) : LispValue do
        LispFloat.new(rng.rand)
      end)

      reg.call("int", 2, 2, ->(args : Array(LispValue)) : LispValue do
        lo = random_int_arg(args[0], "random:int")
        hi = random_int_arg(args[1], "random:int")
        raise LispRuntimeError.new("random:int: min must be <= max") if lo > hi
        LispInt.new(rng.rand(lo..hi))
      end)

      reg.call("seed", 1, 1, ->(args : Array(LispValue)) : LispValue do
        seed = random_int_arg(args[0], "random:seed")
        rng = Random.new(seed.to_u64)
        NIL.as(LispValue)
      end)

      reg.call("choice", 1, 1, ->(args : Array(LispValue)) : LispValue do
        elems = LISP.list_to_a(args[0])
        raise LispRuntimeError.new("random:choice: expects a non-empty list") if elems.empty?
        elems.sample(random: rng)
      end)

      reg.call("shuffle", 1, 1, ->(args : Array(LispValue)) : LispValue do
        elems = LISP.list_to_a(args[0])
        LISP.a_to_list(elems.shuffle(random: rng))
      end)
    end

    private def random_int_arg(v : LispValue, who : String) : Int64
      raise LispRuntimeError.new("#{who}: expected integer, got #{v.write_string}") unless v.is_a?(LispInt)
      v.value
    end
  end
end
