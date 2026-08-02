# ===========================================================================
# raise / raise-continuable / with-exception-handler
# ===========================================================================
#
# @exception_handlers is a stack of installed handler procedures, pushed/
# popped by with-exception-handler around its thunk using the same
# ensure-based save/restore idiom eval_parameterize already established —
# not a new control-flow primitive, just a new stack instance.
#
# `raise` (non-continuable): pops the current handler, calls it with the
# raised object *while that handler is popped* (so a handler that itself
# raises sees the next-outer handler, never itself — R7RS requires this).
# If the handler returns normally instead of escaping (via a continuation
# or a nested raise), that's an error per R7RS — implemented by re-raising
# a SchemeRaise wrapping the same object as a genuine Crystal-exception
# unwind, so the failure still propagates outward (eventually reaching
# guard's rescue, or the top level, uncaught).
#
# `raise-continuable`: same handler lookup/pop, but calls the handler
# directly at its own call site and returns the handler's value in-line —
# no exception unwind in the success path at all, which is exactly why
# this can't be built on Crystal's exception mechanism the way `raise` is.

module Creme::R7RS::Exceptions
  extend self
  include Creme::BuiltinHelpers

  @[Creme::SchemeFn("with-exception-handler", min: 2, max: 2)]
  def with_exception_handler(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    handler, thunk = args[0], args[1]
    interp.exception_handlers << handler
    begin
      interp.apply(thunk, [] of SchemeValue)
    ensure
      interp.exception_handlers.pop?
    end
  end

  @[Creme::SchemeFn("raise", min: 1, max: 1)]
  def raise_(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    obj = args[0]
    handler = interp.exception_handlers.pop?
    raise SchemeRaise.new(obj) unless handler
    begin
      interp.apply(handler, [obj] of SchemeValue)
    ensure
      interp.exception_handlers << handler
    end
    # The handler returned instead of escaping — a non-continuable
    # exception was signalled and there's nowhere for its "result" to
    # go, per R7RS. Unwind as a genuine error so the failure still
    # propagates (to an outer guard, or the top level).
    raise SchemeRaise.new(obj)
  end

  @[Creme::SchemeFn("raise-continuable", min: 1, max: 1)]
  def raise_continuable(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    obj = args[0]
    handler = interp.exception_handlers.pop?
    raise SchemeRaise.new(obj) unless handler
    begin
      interp.apply(handler, [obj] of SchemeValue)
    ensure
      interp.exception_handlers << handler
    end
  end

  @[Creme::SchemeFn("read-error?", min: 1, max: 1)]
  def read_error_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    SchemeBool.of(v.is_a?(SchemeRecord) && v.type.same?(READ_ERROR_TYPE))
  end

  @[Creme::SchemeFn("file-error?", min: 1, max: 1)]
  def file_error_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    SchemeBool.of(v.is_a?(SchemeRecord) && v.type.same?(FILE_ERROR_TYPE))
  end
end

module Creme
  class Interpreter
    private def install_exceptions(env : Env) : Array(String)
      register_module(Creme::R7RS::Exceptions, env)
    end
  end
end
