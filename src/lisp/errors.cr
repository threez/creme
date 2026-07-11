# ===========================================================================
# Exception hierarchy
# ===========================================================================

module LISP
  # One entry in a Lisp-level call stack backtrace: the name of the callable
  # active at that point, and where (in source) it was called from.
  record Frame, name : String, pos : SourcePos?

  class LispError < Exception
    # Lisp-level call stack at the point the error was raised, outermost
    # first, plus the position of the raising form itself. Captured eagerly
    # right here at construction time (not lazily while unwinding — that
    # would need a `rescue` on every recursive `Interpreter#eval` call, which
    # is expensive enough per-frame to blow the real C stack well before
    # `max_eval_depth` is reached). Left empty for errors raised before any
    # interpreter is active (e.g. LispParseError from the reader/lexer).
    property frames : Array(Frame) = [] of Frame
    property pos : SourcePos?

    def initialize(message : String? = nil)
      super(message)
      if interp = Interpreter.current
        @frames = interp.call_stack_snapshot
        @pos = interp.current_pos
      end
    end
  end

  class LispParseError < LispError
  end

  # EOF encountered mid-form: REPL uses this to request a continuation line.
  class LispIncompleteError < LispParseError
  end

  class LispRuntimeError < LispError
  end

  # Raised by (error ...)
  class LispUserError < LispRuntimeError
  end

  # Raised when a host-configured execution budget (max_eval_depth or
  # max_steps) is exceeded.
  class LispExecutionLimitError < LispRuntimeError
  end

  # Raised by the `exit` builtin instead of terminating the process directly.
  # Deliberately not a LispError: hosts that own process lifecycle
  # (src/main.cr) translate this back into a real process exit; treating it
  # as an ordinary runtime error would misreport `(exit N)` as a failure and
  # lose the requested exit code.
  class LispExit < Exception
    getter code : Int32

    def initialize(@code : Int32 = 0)
      super("exit(#{@code})")
    end
  end
end
