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

module Scheme
  class Interpreter
    private def install_exceptions(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(SchemeValue) -> SchemeValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      reg.call("with-exception-handler", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        handler, thunk = args[0], args[1]
        @exception_handlers << handler
        begin
          apply(thunk, [] of SchemeValue)
        ensure
          @exception_handlers.pop?
        end
      end)

      reg.call("raise", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        obj = args[0]
        handler = @exception_handlers.pop?
        raise SchemeRaise.new(obj) unless handler
        begin
          apply(handler, [obj])
        ensure
          @exception_handlers << handler
        end
        # The handler returned instead of escaping — a non-continuable
        # exception was signalled and there's nowhere for its "result" to
        # go, per R7RS. Unwind as a genuine error so the failure still
        # propagates (to an outer guard, or the top level).
        raise SchemeRaise.new(obj)
      end)

      reg.call("raise-continuable", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        obj = args[0]
        handler = @exception_handlers.pop?
        raise SchemeRaise.new(obj) unless handler
        begin
          apply(handler, [obj])
        ensure
          @exception_handlers << handler
        end
      end)

      reg.call("read-error?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        v = args[0]
        SchemeBool.of(v.is_a?(SchemeRecord) && v.type.same?(READ_ERROR_TYPE))
      end)

      reg.call("file-error?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        v = args[0]
        SchemeBool.of(v.is_a?(SchemeRecord) && v.type.same?(FILE_ERROR_TYPE))
      end)
    end
  end
end
