# ===========================================================================
# SchemeValue model (sealed class hierarchy + cons cells)
# ===========================================================================

module Scheme
  # Where a form came from in source text — attached only to Cons (per-form
  # granularity), never to SchemeSym (interned/singleton-per-name, so it can't
  # carry per-occurrence position).
  record SourcePos, file : String, line : Int32, col : Int32

  abstract class SchemeValue
    # Human-readable form (strings unquoted).
    abstract def to_display(io : IO) : Nil

    # Read-back form (strings quoted/escaped). Defaults to to_display.
    def to_write(io : IO) : Nil
      to_display(io)
    end

    def display_string : String
      String.build { |io| to_display(io) }
    end

    def write_string : String
      String.build { |io| to_write(io) }
    end
  end

  class SchemeInt < SchemeValue
    getter value : Int64

    def initialize(@value : Int64)
    end

    def to_display(io : IO) : Nil
      io << @value
    end
  end

  class SchemeFloat < SchemeValue
    getter value : Float64

    def initialize(@value : Float64)
    end

    def to_display(io : IO) : Nil
      v = @value
      if v.nan?
        io << "+nan.0"
      elsif v.infinite? == 1
        io << "+inf.0"
      elsif v.infinite? == -1
        io << "-inf.0"
      elsif v == v.to_i64 && v.abs < 1e15
        io << v.to_i64 << ".0"
      else
        io << v
      end
    end
  end

  class SchemeStr < SchemeValue
    # Crystal String is immutable, so string-set!/string-fill!/string-copy!
    # reassign this property to a newly-built String rather than mutating
    # in place the way SchemeVector's Array-backed value can.
    property value : String

    def initialize(@value : String)
    end

    def to_display(io : IO) : Nil
      io << @value
    end

    def to_write(io : IO) : Nil
      io << '"'
      @value.each_char do |char|
        case char
        when '"'  then io << "\\\""
        when '\\' then io << "\\\\"
        when '\n' then io << "\\n"
        when '\t' then io << "\\t"
        when '\r' then io << "\\r"
        when '\0' then io << "\\0"
        else           io << char
        end
      end
      io << '"'
    end
  end

  class SchemeSym < SchemeValue
    getter name : String

    @@table = {} of String => SchemeSym

    def self.of(name : String) : SchemeSym
      @@table[name] ||= SchemeSym.new(name)
    end

    # Only SchemeSym.of should be used externally; kept public for interning table.
    def initialize(@name : String)
    end

    def to_display(io : IO) : Nil
      io << @name
    end

    # A symbol whose name would not read back as the same identifier if
    # written bare — contains whitespace/parens/quote-family characters, a
    # literal backslash or vertical line, or is empty — must be |...|
    # vertical-bar-escaped so write/read round-trip to the identical symbol,
    # per R7RS §6.5's own guarantee. Ordinary identifiers (the vast
    # majority) pass through unescaped, matching every other Scheme writer.
    private def needs_pipe_escape? : Bool
      return true if @name.empty?
      @name.each_char do |c|
        case c
        when ' ', '\t', '\r', '\n', '(', ')', '[', ']', '"', ';', '\'', '`', ',', '|', '\\'
          return true
        end
      end
      false
    end

    def to_write(io : IO) : Nil
      unless needs_pipe_escape?
        io << @name
        return
      end
      io << '|'
      @name.each_char do |char|
        case char
        when '|'  then io << "\\|"
        when '\\' then io << "\\\\"
        else           io << char
        end
      end
      io << '|'
    end
  end

  class SchemeBool < SchemeValue
    getter? value : Bool

    def initialize(@value : Bool)
    end

    def to_display(io : IO) : Nil
      io << (@value ? "#t" : "#f")
    end
  end

  TRUE  = SchemeBool.new(true)
  FALSE = SchemeBool.new(false)

  class SchemeBool
    def self.of(b : Bool) : SchemeBool
      b ? TRUE : FALSE
    end
  end

  class SchemeNil < SchemeValue
    def to_display(io : IO) : Nil
      io << "()"
    end
  end

  NIL = SchemeNil.new

  class SchemeChar < SchemeValue
    getter value : Char

    def initialize(@value : Char)
    end

    def to_display(io : IO) : Nil
      io << @value
    end

    def to_write(io : IO) : Nil
      io << "#\\"
      case @value
      when ' '      then io << "space"
      when '\n'     then io << "newline"
      when '\t'     then io << "tab"
      when '\r'     then io << "return"
      when '\0'     then io << "null"
      when '\a'     then io << "alarm"
      when '\b'     then io << "backspace"
      when '\u{7F}' then io << "delete"
      when '\u{1B}' then io << "escape"
      else               io << @value
      end
    end
  end

  class Cons < SchemeValue
    property car : SchemeValue
    property cdr : SchemeValue
    property pos : SourcePos?

    # Lazily-populated cache of `Scheme.list_to_a(self.cdr)`, used only by
    # eval_core's special-form arms (if/cond/when/unless/and/or) to avoid
    # re-walking and re-allocating the same source form's argument list on
    # every visit — a hot loop like (if (< n 2) ...) revisits the same Cons
    # node on every call, so caching this array turns an O(visits) cost into
    # O(1) after the first. Invalidated implicitly: mutating car/cdr on a
    # form already cached here (e.g. via set-car!/set-cdr! on quoted/spliced
    # code) would return stale args — not a concern in practice since this
    # cache is only populated for syntax nodes reached through eval_core's
    # special-form dispatch, which are original parsed/macro-expanded source
    # forms, not runtime-mutable data structures.
    property cached_args : Array(SchemeValue)?

    def initialize(@car : SchemeValue, @cdr : SchemeValue, @pos : SourcePos? = nil)
    end

    def to_display(io : IO) : Nil
      write_seq(io, false)
    end

    def to_write(io : IO) : Nil
      write_seq(io, true)
    end

    private def write_seq(io : IO, write_mode : Bool) : Nil
      io << '('
      cur : SchemeValue = self
      first = true
      while cur.is_a?(Cons)
        io << ' ' unless first
        first = false
        if write_mode
          cur.car.to_write(io)
        else
          cur.car.to_display(io)
        end
        cur = cur.cdr
      end
      unless cur.is_a?(SchemeNil)
        io << " . "
        if write_mode
          cur.to_write(io)
        else
          cur.to_display(io)
        end
      end
      io << ')'
    end
  end

  class Lambda < SchemeValue
    getter params : Array(String)
    getter rest : String?
    getter body : Array(SchemeValue)
    getter env : Env
    property name : String

    def initialize(@params : Array(String), @rest : String?, @body : Array(SchemeValue), @env : Env, @name : String = "lambda")
    end

    def to_display(io : IO) : Nil
      io << "#<procedure:" << @name << '>'
    end
  end

  # (case-lambda (formals body...) ...) — a procedure with several arity-
  # specific clauses, each an ordinary Lambda. Dispatch picks the first
  # clause whose arity accepts the call's argument count (fixed-arity
  # clauses need an exact match; a clause with a rest param accepts >=
  # params.size) — see Interpreter#select_case_lambda_clause.
  class CaseLambda < SchemeValue
    getter clauses : Array(Lambda)
    property name : String

    def initialize(@clauses : Array(Lambda), @name : String = "case-lambda")
    end

    def to_display(io : IO) : Nil
      io << "#<procedure:" << @name << '>'
    end
  end

  # A marker bound in @base_env and @global (and hence importable/exportable/renameable
  # like any other identifier) for each core syntactic keyword (if, set!,
  # lambda, let, ...) that eval_core's case statement in interpreter.cr
  # otherwise dispatches on raw symbol text. Carries no behavior itself —
  # `eval_core` checks `bound.is_a?(SchemeSpecialForm)` to decide whether to
  # enter its hardcoded case (this name still means the special form) or
  # fall through to ordinary application (the identifier was shadowed by a
  # local define, a define-syntax, or an import — e.g. R7RS's own
  # (import (except (scheme base) set!) (rename (my lib) (put! set!)))
  # idiom, where `set!` must resolve to the renamed import, not the
  # built-in special form).
  class SchemeSpecialForm < SchemeValue
    getter name : String

    def initialize(@name : String)
    end

    def to_display(io : IO) : Nil
      io << "#<special-form:" << @name << '>'
    end
  end

  class Macro < SchemeValue
    getter params : Array(String)
    getter rest : String?
    getter body : Array(SchemeValue)
    getter env : Env
    property name : String

    def initialize(@params : Array(String), @rest : String?, @body : Array(SchemeValue), @env : Env, @name : String = "macro")
    end

    def to_display(io : IO) : Nil
      io << "#<macro:" << @name << '>'
    end
  end

  class Builtin < SchemeValue
    getter name : String
    getter fn : Array(SchemeValue) -> SchemeValue
    getter min_arity : Int32
    getter max_arity : Int32

    def initialize(@name : String, @min_arity : Int32, @max_arity : Int32, &@fn : Array(SchemeValue) -> SchemeValue)
    end

    def to_display(io : IO) : Nil
      io << "#<builtin:" << @name << '>'
    end
  end

  class SchemeVector < SchemeValue
    getter value : Array(SchemeValue)

    def initialize(@value : Array(SchemeValue) = [] of SchemeValue)
    end

    def to_display(io : IO) : Nil
      write_seq(io, false)
    end

    def to_write(io : IO) : Nil
      write_seq(io, true)
    end

    private def write_seq(io : IO, write_mode : Bool) : Nil
      io << "#("
      @value.each_with_index do |v, i|
        io << ' ' if i > 0
        if write_mode
          v.to_write(io)
        else
          v.to_display(io)
        end
      end
      io << ')'
    end
  end

  # Doubles as R7RS's bytevector type and an opaque-binary-data type (e.g. a
  # SQL BLOB column), modeled on CHICKEN Scheme's blob type — distinct from
  # SchemeStr so binary data never gets silently reinterpreted as text.
  # Lives here rather than in a module file since it wraps a plain Crystal
  # primitive (Bytes) and is shared across modules (sql, convert.cr), not
  # tied to one external library the way SchemeRegex/SchemeDBConnection/
  # SchemeBigDecimal are. Crystal's Bytes (Slice(UInt8)) already supports
  # in-place index assignment, so bytevector-u8-set! needs no new mutation
  # capability here — only a new builtin (see bytevectors.cr).
  class SchemeBlob < SchemeValue
    getter value : Bytes

    def initialize(@value : Bytes)
    end

    def to_display(io : IO) : Nil
      io << "#<blob:" << @value.size << " bytes>"
    end

    # R7RS bytevectors print as #u8(1 2 3 ...) under both display and write
    # — the bytes ARE the printable content, unlike an opaque SQL blob, so
    # this deliberately overrides the more opaque to_display above.
    def to_write(io : IO) : Nil
      io << "#u8("
      @value.each_with_index { |byte, i| io << ' ' if i > 0; io << byte }
      io << ')'
    end
  end

  # A single distinguished value returned by read-char/read-line/read-string
  # at end-of-input, and recognized by eof-object? — same singleton pattern
  # as NIL/TRUE/FALSE.
  class SchemeEof < SchemeValue
    def to_display(io : IO) : Nil
      io << "#<eof>"
    end
  end

  EOF = SchemeEof.new

  # Wraps a Crystal IO as an R7RS port. `input`/`output` are independent
  # (a port is never both in this implementation, matching how
  # open-input-file/open-output-file each hand back a single-direction
  # port) so input-port?/output-port? are simple flag checks rather than
  # capability probes on the underlying IO.
  class SchemePort < SchemeValue
    # Reassignable (not just gettable) so `read` can swap in a fresh
    # IO::Memory holding whatever's left unconsumed after parsing one
    # datum — see Interpreter#read_one_form.
    property io : IO
    getter? input : Bool
    getter? output : Bool
    property? closed : Bool = false
    # true for a bytevector port (open-input-bytevector/open-output-
    # bytevector), false for a textual (string/file) port — read-u8/
    # write-u8/read-bytevector/etc. only operate on binary ports, and
    # binary-port?/textual-port? are simple flag checks against this.
    getter? binary : Bool

    def initialize(@io : IO, @input : Bool, @output : Bool, @binary : Bool = false)
    end

    def to_display(io : IO) : Nil
      kind = @input ? "input" : "output"
      io << "#<" << kind << "-port" << (@closed ? " closed" : "") << '>'
    end
  end

  # A memoized delay/force promise. `thunk_expr`/`thunk_env` hold the
  # unevaluated body closed over its definition env; `force` (an ordinary
  # builtin, since forcing needs no special evaluation rule) evaluates them
  # once, memoizes into `value`, then clears them so the env isn't held
  # alive after the promise is forced.
  class SchemePromise < SchemeValue
    property? forced : Bool = false
    property value : SchemeValue = NIL
    property thunk_expr : SchemeValue?
    property thunk_env : Env?

    def initialize(@thunk_expr : SchemeValue, @thunk_env : Env)
    end

    def to_display(io : IO) : Nil
      io << "#<promise" << (@forced ? " forced" : "") << '>'
    end
  end

  # An R7RS parameter object: a mutable current value plus an optional
  # converter procedure applied whenever the value changes (at creation and
  # on every `parameterize` rebind). Made callable via a dedicated arm in
  # Interpreter#apply so `(p)` reads the current value; mutation only
  # happens through `parameterize`, never by calling `p` with an argument.
  class SchemeParameter < SchemeValue
    property value : SchemeValue
    property converter : SchemeValue?

    def initialize(@value : SchemeValue, @converter : SchemeValue? = nil)
    end

    def to_display(io : IO) : Nil
      io << "#<parameter>"
    end
  end

  # An "environment specifier" (R7RS §6.12) — a first-class handle on an
  # Env, returned by environment/scheme-report-environment/null-environment/
  # interaction-environment and consumed by eval's optional second
  # argument. The bindings themselves are still ordinary Env entries; this
  # is just enough of a wrapper to let Scheme code pass an Env around as a
  # value without exposing Env itself as a SchemeValue.
  class SchemeEnvironment < SchemeValue
    getter env : Env

    def initialize(@env : Env)
    end

    def to_display(io : IO) : Nil
      io << "#<environment>"
    end
  end

  # Carries multiple return values from `values` to `call-with-values`. Only
  # ever produced by `values` when called with a count other than 1 — a
  # single-value `(values x)` returns x directly, not a wrapped one-element
  # SchemeValues, so `values` behaves transparently in ordinary (non
  # call-with-values) contexts, per R7RS.
  class SchemeValues < SchemeValue
    getter items : Array(SchemeValue)

    def initialize(@items : Array(SchemeValue))
    end

    def to_display(io : IO) : Nil
      io << "#<values"
      @items.each { |v| io << ' ' << v.display_string }
      io << '>'
    end
  end

  # A captured escape continuation (call/cc). Only valid while its
  # originating call/cc frame is still live on the Crystal stack — see
  # Interpreter#apply's SchemeContinuation arm and the call_cc builtin's
  # @live_continuation_tags bookkeeping. Not a full re-entrant continuation:
  # invoking it after its call/cc has already returned raises
  # SchemeRuntimeError rather than resuming.
  class SchemeContinuation < SchemeValue
    getter tag : Int64

    def initialize(@tag : Int64)
    end

    def to_display(io : IO) : Nil
      io << "#<continuation>"
    end
  end
end
