# ===========================================================================
# LispValue model (sealed class hierarchy + cons cells)
# ===========================================================================

module LISP
  abstract class LispValue
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

  class LispInt < LispValue
    getter value : Int64

    def initialize(@value : Int64)
    end

    def to_display(io : IO) : Nil
      io << @value
    end
  end

  class LispFloat < LispValue
    getter value : Float64

    def initialize(@value : Float64)
    end

    def to_display(io : IO) : Nil
      v = @value
      if v.finite? && v == v.to_i64 && v.abs < 1e15
        io << v.to_i64 << ".0"
      else
        io << v
      end
    end
  end

  class LispStr < LispValue
    getter value : String

    def initialize(@value : String)
    end

    def to_display(io : IO) : Nil
      io << @value
    end

    def to_write(io : IO) : Nil
      io << '"'
      @value.each_char do |c|
        case c
        when '"'  then io << "\\\""
        when '\\' then io << "\\\\"
        when '\n' then io << "\\n"
        when '\t' then io << "\\t"
        when '\r' then io << "\\r"
        when '\0' then io << "\\0"
        else           io << c
        end
      end
      io << '"'
    end
  end

  class LispSym < LispValue
    getter name : String

    @@table = {} of String => LispSym

    def self.of(name : String) : LispSym
      @@table[name] ||= LispSym.new(name)
    end

    # Only LispSym.of should be used externally; kept public for interning table.
    def initialize(@name : String)
    end

    def to_display(io : IO) : Nil
      io << @name
    end
  end

  class LispBool < LispValue
    getter value : Bool

    def initialize(@value : Bool)
    end

    def to_display(io : IO) : Nil
      io << (@value ? "#t" : "#f")
    end
  end

  TRUE  = LispBool.new(true)
  FALSE = LispBool.new(false)

  class LispBool
    def self.of(b : Bool) : LispBool
      b ? TRUE : FALSE
    end
  end

  class LispNil < LispValue
    def to_display(io : IO) : Nil
      io << "()"
    end
  end

  NIL = LispNil.new

  class LispChar < LispValue
    getter value : Char

    def initialize(@value : Char)
    end

    def to_display(io : IO) : Nil
      io << @value
    end

    def to_write(io : IO) : Nil
      io << "#\\"
      case @value
      when ' '  then io << "space"
      when '\n' then io << "newline"
      when '\t' then io << "tab"
      when '\r' then io << "return"
      when '\0' then io << "nul"
      else           io << @value
      end
    end
  end

  class Cons < LispValue
    property car : LispValue
    property cdr : LispValue

    def initialize(@car : LispValue, @cdr : LispValue)
    end

    def to_display(io : IO) : Nil
      write_seq(io, false)
    end

    def to_write(io : IO) : Nil
      write_seq(io, true)
    end

    private def write_seq(io : IO, write_mode : Bool) : Nil
      io << '('
      cur : LispValue = self
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
      unless cur.is_a?(LispNil)
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

  class Lambda < LispValue
    getter params : Array(String)
    getter rest : String?
    getter body : Array(LispValue)
    getter env : Env
    property name : String

    def initialize(@params : Array(String), @rest : String?, @body : Array(LispValue), @env : Env, @name : String = "lambda")
    end

    def to_display(io : IO) : Nil
      io << "#<procedure:" << @name << '>'
    end
  end

  class Macro < LispValue
    getter params : Array(String)
    getter rest : String?
    getter body : Array(LispValue)
    getter env : Env
    property name : String

    def initialize(@params : Array(String), @rest : String?, @body : Array(LispValue), @env : Env, @name : String = "macro")
    end

    def to_display(io : IO) : Nil
      io << "#<macro:" << @name << '>'
    end
  end

  class Builtin < LispValue
    getter name : String
    getter fn : Array(LispValue) -> LispValue
    getter min_arity : Int32
    getter max_arity : Int32

    def initialize(@name : String, @min_arity : Int32, @max_arity : Int32, &@fn : Array(LispValue) -> LispValue)
    end

    def to_display(io : IO) : Nil
      io << "#<builtin:" << @name << '>'
    end
  end

  class LispVector < LispValue
    getter value : Array(LispValue)

    def initialize(@value : Array(LispValue) = [] of LispValue)
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

  # Opaque binary data, modeled on CHICKEN Scheme's blob type — distinct from
  # LispStr so binary data (e.g. a SQL BLOB column) never gets silently
  # reinterpreted as text. Lives here rather than in a module file since it
  # wraps a plain Crystal primitive (Bytes) and is shared across modules
  # (sql, convert.cr), not tied to one external library the way LispRegex/
  # LispDBConnection/LispBigDecimal are.
  class LispBlob < LispValue
    getter value : Bytes

    def initialize(@value : Bytes)
    end

    def to_display(io : IO) : Nil
      io << "#<blob:" << @value.size << " bytes>"
    end
  end
end
