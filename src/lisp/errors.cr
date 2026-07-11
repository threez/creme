# ===========================================================================
# Exception hierarchy
# ===========================================================================

module LISP
  class LispError < Exception
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
