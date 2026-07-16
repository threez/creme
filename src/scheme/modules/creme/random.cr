# ===========================================================================
# random module: random numbers, choices, shuffling (SRFI-27 naming where
# a direct equivalent exists: random-real is exactly SRFI-27's
# (random-real), and random-integer matches SRFI-27's exact single-bound,
# zero-based, exclusive-upper-bound (random-integer n) -> [0, n) contract —
# not this module's old two-arg inclusive-range signature).
# ===========================================================================

module Scheme::Builtins::RandomLibrary
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("random-real", min: 0, max: 0)]
  def random_real(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeFloat.new(interp.random_rng.rand)
  end

  @[Scheme::SchemeFn("random-integer", min: 1, max: 1)]
  def random_integer(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    n = random_int_arg(args[0], "random-integer")
    raise SchemeRuntimeError.new("random-integer: n must be positive") if n <= 0
    SchemeInt.new(interp.random_rng.rand(n))
  end

  @[Scheme::SchemeFn("random-seed!", min: 1, max: 1)]
  def random_seed(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    seed = random_int_arg(args[0], "random-seed!")
    interp.random_rng = Random.new(seed.to_u64)
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("random-choice", min: 1, max: 1)]
  def random_choice(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    elems = Scheme.list_to_a(args[0])
    raise SchemeRuntimeError.new("random-choice: expects a non-empty list") if elems.empty?
    elems.sample(random: interp.random_rng)
  end

  @[Scheme::SchemeFn("random-shuffle", min: 1, max: 1)]
  def random_shuffle(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    elems = Scheme.list_to_a(args[0])
    Scheme.a_to_list(elems.shuffle(random: interp.random_rng))
  end

  private def random_int_arg(v : SchemeValue, who : String) : Int64
    raise SchemeRuntimeError.new("#{who}: expected integer, got #{v.write_string}") unless v.is_a?(SchemeInt)
    v.value
  end
end

module Scheme
  class Interpreter
    register_library ["creme", "random"], Scheme::Builtins::RandomLibrary
  end
end
