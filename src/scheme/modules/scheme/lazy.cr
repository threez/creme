# ===========================================================================
# (scheme lazy)
# ===========================================================================
#
# force/make-promise/promise? are ordinary procedures owned here.
# delay/delay-force are special forms recognized by the analyzer — bound
# in @base_env via install_special_forms — so they're borrowed as
# SchemeSpecialForm markers rather than being annotatable methods.

module Scheme::Builtins::LazyLibrary
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("promise?", min: 1, max: 1)]
  def promise_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(args[0].is_a?(SchemePromise))
  end

  @[Scheme::SchemeFn("make-promise", min: 1, max: 1)]
  def make_promise(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    if v.is_a?(SchemePromise)
      v.as(SchemeValue)
    else
      SchemePromise.new(forced_value: v).as(SchemeValue)
    end
  end

  # Forcing a non-promise just returns it unchanged (R7RS: `force`
  # accepts ordinary values for programs written before promises
  # existed). Forcing an already-forced promise returns the memoized
  # value without re-evaluating the thunk.
  # Loops rather than single-stepping so a delay-force chain (where a
  # forced thunk's own result is itself another promise, R7RS's
  # "iterative lazy evaluation" idiom) resolves without growing the
  # Crystal stack one eval() frame per link — each promise in the chain
  # gets forced and its result fed into the next iteration in the same
  # loop, not via recursive force-of-force calls.
  @[Scheme::SchemeFn("force", min: 1, max: 1)]
  def force(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    while v.is_a?(SchemePromise)
      unless v.forced?
        thunk_closure = v.thunk_closure
        raise SchemeRuntimeError.new("force: promise has no thunk") unless thunk_closure
        result = interp.apply(thunk_closure, [] of SchemeValue)
        unless v.forced?
          v.value = result
          v.forced = true
          v.thunk_closure = nil
        end
      end
      v = v.value
    end
    v
  end
end

module Scheme
  class Interpreter
    register_library ["scheme", "lazy"] do |env|
      own = register_module(Scheme::Builtins::LazyLibrary, env)
      %w[delay delay-force].each { |name| env.define(name, SchemeSpecialForm.new(name)) }
      own + %w[delay delay-force]
    end
  end
end
