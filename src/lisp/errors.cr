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
end
