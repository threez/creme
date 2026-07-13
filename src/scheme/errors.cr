# ===========================================================================
# Exception hierarchy
# ===========================================================================

module Scheme
  # One entry in a Scheme-level call stack backtrace: the name of the callable
  # active at that point, and where (in source) it was called from.
  record Frame, name : String, pos : SourcePos?

  class SchemeError < Exception
    # Scheme-level call stack at the point the error was raised, outermost
    # first, plus the position of the raising form itself. Captured eagerly
    # right here at construction time (not lazily while unwinding — that
    # would need a `rescue` on every recursive `Interpreter#eval` call, which
    # is expensive enough per-frame to blow the real C stack well before
    # `max_eval_depth` is reached). Left empty for errors raised before any
    # interpreter is active (e.g. SchemeParseError from the reader/lexer).
    property frames : Array(Frame) = [] of Frame
    property pos : SourcePos?

    # The structured condition object this error carries, if any — set by
    # `error` (a SchemeRecord of the error-object condition type, message +
    # un-stringified irritants) so `guard` can hand callers something richer
    # than a joined string. Left nil for errors that never went through
    # `error` (e.g. "unbound variable"); `guard` synthesizes a fallback
    # condition from `message` in that case. Lives on the common base class,
    # not just SchemeUserError, so a future structured-raise mechanism for
    # other error kinds can reuse the same field.
    property payload : SchemeValue?

    def initialize(message : String? = nil)
      super(message)
      if interp = Interpreter.current
        @frames = interp.call_stack_snapshot
        @pos = interp.current_pos
      end
    end
  end

  class SchemeParseError < SchemeError
  end

  # EOF encountered mid-form: REPL uses this to request a continuation line.
  class SchemeIncompleteError < SchemeParseError
  end

  class SchemeRuntimeError < SchemeError
  end

  # Raised by (error ...)
  class SchemeUserError < SchemeRuntimeError
  end

  # Raised by (raise obj) / a handler-return fallback from (raise-continuable
  # obj) — payload is ALWAYS set to the raw raised Scheme object (unlike the
  # base class's payload, which is nil unless something went through
  # `error`), since raise accepts any object, not just condition records.
  # See interpreter/exceptions.cr.
  class SchemeRaise < SchemeError
    def initialize(@payload : SchemeValue)
      super(nil)
    end
  end

  # (creme file)'s I/O operations raise this instead of a bare
  # SchemeRuntimeError so `file-error?` can distinguish file errors from
  # other runtime errors. Sets its own payload (a FILE_ERROR_TYPE record) at
  # construction so guard's existing `ex.payload ||` fallback picks it up
  # automatically — file-error? just checks the payload's record type.
  class SchemeFileError < SchemeRuntimeError
    def initialize(message : String? = nil)
      super(message)
      @payload = SchemeRecord.new(FILE_ERROR_TYPE, [SchemeStr.new(message || "file error"), NIL] of SchemeValue)
    end
  end

  # The reader raises this for malformed/incomplete syntax reached through
  # `read`, so `read-error?` can distinguish it from other parse errors.
  # Same self-tagging payload pattern as SchemeFileError.
  class SchemeReadError < SchemeParseError
    def initialize(message : String? = nil)
      super(message)
      @payload = SchemeRecord.new(READ_ERROR_TYPE, [SchemeStr.new(message || "read error"), NIL] of SchemeValue)
    end
  end

  # Raised when a host-configured execution budget (max_eval_depth or
  # max_steps) is exceeded.
  class SchemeExecutionLimitError < SchemeRuntimeError
  end

  # Raised by the `exit` builtin instead of terminating the process directly.
  # Deliberately not a SchemeError: hosts that own process lifecycle
  # (src/main.cr) translate this back into a real process exit; treating it
  # as an ordinary runtime error would misreport `(exit N)` as a failure and
  # lose the requested exit code.
  class SchemeExit < Exception
    getter code : Int32

    def initialize(@code : Int32 = 0)
      super("exit(#{@code})")
    end
  end

  # Raised by invoking a SchemeContinuation captured by call/cc, to unwind the
  # Crystal call stack back to that continuation's originating call/cc frame.
  # Deliberately not a SchemeError, for the same reason as SchemeExit: `guard`
  # must not be able to intercept an in-flight continuation invocation, and
  # only the matching call/cc frame's own rescue (matched by tag) should ever
  # catch this — every other frame it passes through must let it propagate
  # untouched.
  class ContinuationInvoked < Exception
    getter tag : Int64
    getter value : SchemeValue

    def initialize(@tag : Int64, @value : SchemeValue)
      super("continuation invoked")
    end
  end
end
