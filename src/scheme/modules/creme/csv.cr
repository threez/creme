# ===========================================================================
# csv module: parse/build CSV, both bulk (whole string in/out) and streaming
# (row-by-row over a port) via a small, self-contained CSV engine
# (Scheme::Csv, below) -- no external shard/vendored dependency. This used
# to wrap `lib/fastcsv` (itself a performance-tuned fork of Crystal stdlib's
# CSV module); that dependency is gone, and the parts of its API this
# project never used (the header-aware instance wrapper with its Row
# struct, `strip`, `rewind`, regex-header lookup, etc.) are gone with it --
# only what `(creme csv)`'s own builtins actually need remains: a
# `Lexer`/`Parser` pair (still IO-chunked -- see Lexer::IOBased's own
# comment -- for the same reason FastCSV existed at all: profiling a
# multi-million-row CSV import found `IO#read_char`-per-character
# dominating wall time) and a `Builder` for writing.
#
# `Parser#next_row` builds Scheme values DIRECTLY as it lexes -- a cell's
# already-decoded Crystal `String` becomes a `SchemeStr` the moment the
# lexer resolves it, with no intermediate `Array(String)` row (built once,
# then re-mapped into Scheme values in a second pass) in between, the way
# the old FastCSV-backed version worked. csv-read-headers goes further:
# each header cell's `SchemeStr` is resolved exactly once and then reused
# (not re-wrapped) as the key of every row's alist pair for that column.
#
# Bulk reads decode rows into vectors of strings (csv-read) or, with a
# header row, an alist of (header . cell) per row (csv-read-headers) — the
# same "arrays -> vectors, objects -> alists" convention (creme json) uses.
# Bulk/streaming writers accept cells as strings, chars, numbers, or
# booleans and hand them to Scheme::Csv::Builder as native Crystal values so
# it decides quoting/formatting itself.
# ===========================================================================

# A small, self-contained CSV engine: line-for-line derived from Crystal
# stdlib's own `CSV` (the same lineage `lib/fastcsv` forked from), trimmed
# to exactly what `Scheme::Builtins::CsvLibrary` below needs.
module Scheme::Csv
  DEFAULT_SEPARATOR  = ','
  DEFAULT_QUOTE_CHAR = '"'

  # Default raw-read chunk size for a streaming (IO-backed) parser -- see
  # Lexer::IOBased's own comment. Hoisted to module level (rather than
  # left as Lexer::IOBased's own constant) so (creme sql)'s csv-import!,
  # a second consumer of Parser outside this file, has one obvious place
  # to reference it.
  DEFAULT_CHUNK_SIZE = 65536

  # Raised when an error related to a CSV is found.
  class Error < Exception
  end

  # Raised when an error is encountered during CSV parsing.
  class MalformedError < Error
    getter line_number : Int32
    getter column_number : Int32

    def initialize(message : String, @line_number : Int32, @column_number : Int32)
      super("#{message} at line #{@line_number}, column #{@column_number}")
    end
  end

  # :nodoc: A token in a CSV -- internal to Lexer/Parser; not private only
  # so spec/scheme/modules/creme/csv_engine_spec.cr can exercise Lexer
  # directly at the token level (the same correctness suite the vendored
  # lib/fastcsv this replaced used to carry).
  struct Token
    enum Kind
      Cell
      Newline
      Eof
    end

    property kind : Kind
    property value : String

    def initialize
      @kind = Kind::Cell
      @value = ""
    end
  end

  # :nodoc: token-level state machine driving both Lexer subclasses below --
  # unmodified from stdlib/FastCSV's own lineage; the only genuinely
  # different piece is IOBased's chunked refill strategy (see its own
  # comment).
  abstract class Lexer
    def self.new(string : String, separator : Char = DEFAULT_SEPARATOR, quote_char : Char = DEFAULT_QUOTE_CHAR,
                 chunk_size : Int32 = DEFAULT_CHUNK_SIZE) : Lexer
      StringBased.new(string, separator, quote_char)
    end

    def self.new(io : IO, separator : Char = DEFAULT_SEPARATOR, quote_char : Char = DEFAULT_QUOTE_CHAR,
                 chunk_size : Int32 = DEFAULT_CHUNK_SIZE) : Lexer
      IOBased.new(io, separator, quote_char, chunk_size)
    end

    getter token : Token

    def initialize(@separator : Char = DEFAULT_SEPARATOR, @quote_char : Char = DEFAULT_QUOTE_CHAR)
      @token = Token.new
      @buffer = IO::Memory.new
      @column_number = 1
      @line_number = 1
      @last_empty_column = false

      # When the lexer finds \n or \r it produces a newline token but
      # doesn't eagerly consume the next token -- so a streaming reader
      # produces a row as soon as a newline is reached, without waiting
      # for more content.
      @last_was_slash_r = false
      @last_was_slash_n = false
    end

    private abstract def consume_unquoted_cell
    private abstract def next_char_no_column_increment
    private abstract def current_char

    def next_token : Token
      if @last_empty_column
        @last_empty_column = false
        @token.kind = Token::Kind::Cell
        @token.value = ""
        return @token
      end

      if @last_was_slash_r
        next_char if next_char == '\n'
        @last_was_slash_r = false
      elsif @last_was_slash_n
        next_char
        @last_was_slash_n = false
      end

      case current_char
      when '\0'
        @token.kind = Token::Kind::Eof
      when @separator
        @token.kind = Token::Kind::Cell
        @token.value = ""
        check_last_empty_column
      when '\r'
        @token.kind = Token::Kind::Newline
        @last_was_slash_r = true
      when '\n'
        @token.kind = Token::Kind::Newline
        @last_was_slash_n = true
      when @quote_char
        @token.kind = Token::Kind::Cell
        @token.value = consume_quoted_cell
      else
        @token.kind = Token::Kind::Cell
        @token.value = consume_unquoted_cell
      end
      @token
    end

    private def consume_quoted_cell
      @buffer.clear
      while true
        case char = next_char
        when '\0'
          raise "Unclosed quote"
        when @quote_char
          case next_char
          when @separator
            check_last_empty_column
            break
          when '\r', '\n', '\0'
            break
          when @quote_char
            @buffer << @quote_char
          else
            raise "Expecting comma, newline or end, not #{current_char.inspect}"
          end
        else
          @buffer << char
        end
      end
      @buffer.to_s
    end

    private def check_last_empty_column
      case next_char
      when '\r', '\n', '\0'
        @last_empty_column = true
      else
        # not empty
      end
    end

    private def next_char
      @column_number += 1
      char = next_char_no_column_increment
      if char.in?('\n', '\r')
        @column_number = 0
        @line_number += 1
      end
      char
    end

    private def raise(msg)
      ::raise MalformedError.new(msg, @line_number, @column_number)
    end
  end

  # :nodoc: zero-copy (byte_slice directly on the source string) lexer for
  # a bulk (whole-string) parse -- no IO/chunking involved at all.
  class Lexer::StringBased < Lexer
    def initialize(string : String, separator : Char = DEFAULT_SEPARATOR, quote_char : Char = DEFAULT_QUOTE_CHAR)
      super(separator, quote_char)
      @reader = Char::Reader.new(string)
      if @reader.current_char == '\n'
        @line_number += 1
        @column_number = 0
      end
    end

    private def consume_unquoted_cell
      start_pos = @reader.pos
      end_pos = start_pos
      while true
        case next_char
        when @separator
          end_pos = @reader.pos
          check_last_empty_column
          break
        when '\r', '\n', '\0'
          end_pos = @reader.pos
          break
        when @quote_char
          raise "Unexpected quote"
        end
      end
      @reader.string.byte_slice(start_pos, end_pos - start_pos)
    end

    private def next_char_no_column_increment
      @reader.next_char
    end

    private def current_char
      @reader.current_char
    end
  end

  # :nodoc: streaming lexer over an IO, reading in CHUNK_SIZE-byte chunks
  # via a raw `IO#read(Bytes)` call and lexing each chunk through a
  # `Char::Reader` (the same zero-copy path StringBased uses) instead of
  # one `IO#read_char` call per character -- profiling a multi-million-row
  # CSV import found that per-character IO dispatch dominating wall time.
  # `fill_buffer` carries any incomplete trailing UTF-8 sequence over to
  # the next chunk rather than decoding it (which would corrupt it or
  # silently replace it with U+FFFD) -- see its own comment. Memory use is
  # bounded by chunk_size regardless of input size: genuine streaming.
  class Lexer::IOBased < Lexer
    # A one-NUL-byte string decodes to exactly the sentinel `'\0'` the base
    # Lexer's `next_token` already treats as EOF.
    EOF_STRING = String.new(Bytes[0_u8])

    def initialize(@io : IO, separator : Char = DEFAULT_SEPARATOR, quote_char : Char = DEFAULT_QUOTE_CHAR,
                   chunk_size : Int32 = DEFAULT_CHUNK_SIZE)
      super(separator, quote_char)
      @leftover = Bytes.empty
      # Allocated once and reused by every fill_buffer call -- Bytes.new
      # zero-initializes its whole size on every call, a real cost paid
      # for no reason since the buffer's content is always fully
      # overwritten before anything reads from it.
      @raw_buffer = Bytes.new(chunk_size)
      @reader = Char::Reader.new(EOF_STRING)
      fill_buffer
      @current_char = @reader.current_char
    end

    # Zero-copy in the overwhelming common case (a cell that doesn't
    # straddle a chunk-refill boundary): a single byte_slice directly on
    # the current chunk's already-decoded string. Falls back to
    # accumulating through @buffer only on the rare cell that DOES cross
    # a chunk boundary, detected via `same?` (object identity, not `==`)
    # since fill_buffer swaps in a genuinely new Char::Reader/string
    # exactly when a refill happens.
    private def consume_unquoted_cell
      chunk = @reader.string
      chunk_start = @reader.pos
      crossed = false
      while true
        case current_char
        when @separator
          cell = finish_unquoted_cell(chunk, chunk_start, crossed)
          check_last_empty_column
          return cell
        when '\r', '\n', '\0'
          return finish_unquoted_cell(chunk, chunk_start, crossed)
        when @quote_char
          raise "Unexpected quote"
        else
          next_char
          unless @reader.string.same?(chunk)
            @buffer.clear unless crossed
            @buffer << chunk.byte_slice(chunk_start, chunk.bytesize - chunk_start)
            crossed = true
            chunk = @reader.string
            chunk_start = 0
          end
        end
      end
    end

    private def finish_unquoted_cell(chunk : String, chunk_start : Int32, crossed : Bool) : String
      if crossed
        @buffer << chunk.byte_slice(chunk_start, @reader.pos - chunk_start)
        @buffer.to_s
      else
        chunk.byte_slice(chunk_start, @reader.pos - chunk_start)
      end
    end

    private getter current_char

    private def next_char_no_column_increment
      if char = @reader.next_char?
        @current_char = char
      else
        fill_buffer
        @current_char = @reader.current_char
      end
    end

    # Pulls the next chunk from @io (prefixed by any incomplete UTF-8 tail
    # carried over from the previous chunk) and starts a fresh
    # Char::Reader over the valid-UTF8 prefix of what was read, carrying
    # any new dangling tail forward. `read` returning 0 is genuine EOF
    # (represented the same sentinel-'\0' way as true string EOF). `IO#read`
    # is only required to return AT LEAST ONE byte when more data remains
    # (not to fill the whole slice), so this loops until either a complete
    # character is available or genuine EOF is reached -- handing back a
    # reader over an empty string too early would make the lexer mistake
    # "no complete character decoded YET" for "input has ended".
    private def fill_buffer : Nil
      @leftover.copy_to(@raw_buffer)
      total = @leftover.size
      loop do
        read = @io.read(@raw_buffer + total)
        if read.zero?
          if total.zero?
            @reader = Char::Reader.new(EOF_STRING)
          else
            # Genuine EOF with a never-completed dangling tail -- decode
            # it as-is rather than looping forever; only reachable for a
            # truncated/malformed input.
            @reader = Char::Reader.new(String.new(@raw_buffer[0, total]))
            @leftover = Bytes.empty
          end
          return
        end

        total += read
        incomplete = incomplete_tail_length(@raw_buffer, total)
        usable = total - incomplete
        next if usable.zero? && total < @raw_buffer.size

        # Only reachable with a pathologically tiny chunk_size (smaller
        # than the longest UTF-8 sequence) that can never hold one
        # complete multi-byte character -- decode what's there as-is.
        usable = total if usable.zero?
        @reader = Char::Reader.new(String.new(@raw_buffer[0, usable]))
        @leftover = incomplete.zero? ? Bytes.empty : @raw_buffer[usable, incomplete].dup
        return
      end
    end

    # UTF-8's own self-describing length rule: a byte's high bits say
    # whether it's a single-byte (ASCII) character, the leading byte of a
    # 2/3/4-byte sequence, or a continuation byte. Returns 0 for a
    # continuation byte or a byte that isn't valid UTF-8 to begin with.
    private def utf8_leader_length(byte : UInt8) : Int32
      case
      when byte & 0x80 == 0x00 then 1
      when byte & 0xE0 == 0xC0 then 2
      when byte & 0xF0 == 0xE0 then 3
      when byte & 0xF8 == 0xF0 then 4
      else                          0
      end
    end

    # How many bytes at the very end of bytes[0, size] form an INCOMPLETE
    # multi-byte UTF-8 sequence that must be carried over to the next
    # chunk rather than decoded now.
    private def incomplete_tail_length(bytes : Bytes, size : Int32) : Int32
      scan_limit = Math.min(3, size)
      i = 1
      while i <= scan_limit
        byte = bytes[size - i]
        unless byte & 0xC0 == 0x80 # a leader byte (or plain ASCII), not a continuation byte
          needed = utf8_leader_length(byte)
          return needed > i ? i : 0
        end
        i += 1
      end
      # 3 continuation bytes in a row with no leader within range isn't
      # valid UTF-8 at all -- nothing meaningful to carry over.
      0
    end
  end

  # A CSV parser: consumes a String or IO row by row.
  class Parser
    def initialize(string_or_io : String | IO, separator : Char = DEFAULT_SEPARATOR, quote_char : Char = DEFAULT_QUOTE_CHAR,
                   chunk_size : Int32 = DEFAULT_CHUNK_SIZE)
      @lexer = Lexer.new(string_or_io, separator, quote_char, chunk_size)
      @max_row_size = 3
    end

    # The next row's cells, each passed through the given block right
    # where the lexer resolves its text -- so a caller builds exactly the
    # type it wants (a SchemeStr for (creme csv), a plain String for
    # (creme sql)'s csv-import!, which binds cells straight to a DB
    # parameter) in ONE pass, with no intermediate Array(String) row built
    # and then re-mapped into the wanted type afterward. `nil` at EOF.
    def next_row(& : String -> U) : Array(U)? forall U
      token = @lexer.next_token
      return nil if token.kind.eof?

      cells = Array(U).new(@max_row_size)
      loop do
        case token.kind
        when .cell?
          cells << yield token.value
          token = @lexer.next_token
        else # :newline, :eof
          @max_row_size = cells.size if cells.size > @max_row_size
          return cells
        end
      end
    end

    # The next row's cells as plain Strings -- the default shape, matching
    # this project's other CSV consumer, (creme sql)'s csv-import!.
    def next_row : Array(String)?
      next_row { |cell| cell }
    end
  end

  # Writes CSV to an IO.
  class Builder
    enum Quoting
      # No quotes
      NONE

      # Quotes according to RFC 4180 (default)
      RFC

      # Always quote
      ALL
    end

    def initialize(@io : IO, @separator : Char = DEFAULT_SEPARATOR, @quote_char : Char = DEFAULT_QUOTE_CHAR, @quoting : Quoting = Quoting::RFC)
      @first_cell_in_row = true
    end

    # Yields a Builder::Row to append a row; a newline is appended after.
    def row(&) : Nil
      yield Row.new(self, @separator, @quote_char, @quoting)
      @io << '\n'
      @first_cell_in_row = true
    end

    # Appends the given values as a single row, then a newline.
    def row(values : Enumerable) : Nil
      row { |row| values.each { |value| row << value } }
    end

    # :ditto:
    def row(*values) : Nil
      row values
    end

    # :nodoc:
    def cell(&) : Nil
      append_cell { yield @io }
    end

    # :nodoc:
    def quote_cell(value : String) : Nil
      append_cell do
        @io << @quote_char
        value.each_char do |char|
          case char
          when @quote_char
            @io << @quote_char << @quote_char
          else
            @io << char
          end
        end
        @io << @quote_char
      end
    end

    private def append_cell(&) : Nil
      @io << @separator unless @first_cell_in_row
      yield
      @first_cell_in_row = false
    end

    # A CSV row being built.
    struct Row
      @builder : Builder

      def initialize(@builder, @separator : Char = DEFAULT_SEPARATOR, @quote_char : Char = DEFAULT_QUOTE_CHAR, @quoting : Quoting = Quoting::RFC)
      end

      def <<(value : String) : Nil
        if needs_quotes?(value)
          @builder.quote_cell value
        else
          @builder.cell { |io| io << value }
        end
      end

      def <<(value : Nil | Bool | Number) : Nil
        case @quoting
        when .all?
          @builder.cell { |io| io << @quote_char; io << value; io << @quote_char }
        else
          @builder.cell { |io| io << value }
        end
      end

      private def needs_quotes?(value : String)
        case @quoting
        when .rfc?
          value.each_byte do |byte|
            case byte.unsafe_chr
            when @separator, @quote_char, '\n'
              return true
            else
              # keep scanning
            end
          end
          false
        when .all?
          true
        else
          false
        end
      end
    end
  end
end

module Scheme::Builtins::CsvLibrary
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("csv-read", min: 1, max: 3)]
  def csv_read(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    s = string_arg(args[0], "csv-read")
    sep = csv_separator_arg(args, 1, "csv-read")
    quote = csv_quote_char_arg(args, 2, "csv-read")
    parser = Scheme::Csv::Parser.new(s, sep, quote)
    rows = [] of SchemeValue
    while (cells = parser.next_row { |cell| SchemeStr.new(cell).as(SchemeValue) })
      rows << SchemeVector.new(cells)
    end
    SchemeVector.new(rows)
  rescue ex : Scheme::Csv::Error
    raise SchemeRuntimeError.new("csv-read: #{ex.message}")
  end

  @[Scheme::SchemeFn("csv-read-headers", min: 1, max: 3)]
  def csv_read_headers(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    s = string_arg(args[0], "csv-read-headers")
    sep = csv_separator_arg(args, 1, "csv-read-headers")
    quote = csv_quote_char_arg(args, 2, "csv-read-headers")
    parser = Scheme::Csv::Parser.new(s, sep, quote)
    to_scheme = ->(cell : String) { SchemeStr.new(cell).as(SchemeValue) }
    headers = parser.next_row(&to_scheme) || ([] of SchemeValue)
    rows = [] of SchemeValue
    while (cells = parser.next_row(&to_scheme))
      pairs = headers.map_with_index { |header, i| Cons.new(header, cells[i]).as(SchemeValue) }
      rows << Scheme.a_to_list(pairs)
    end
    SchemeVector.new(rows)
  rescue ex : Scheme::Csv::Error
    raise SchemeRuntimeError.new("csv-read-headers: #{ex.message}")
  end

  @[Scheme::SchemeFn("csv-write", min: 1, max: 3)]
  def csv_write(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    rows = csv_row_cells(args[0], "csv-write").map { |row| csv_row_cells(row, "csv-write") }
    sep = csv_separator_arg(args, 1, "csv-write")
    quoting = csv_quoting_arg(args, 2, "csv-write")
    text = String.build do |io|
      builder = Scheme::Csv::Builder.new(io, sep, quoting: quoting)
      rows.each { |row| csv_write_row(builder, row, "csv-write") }
    end
    SchemeStr.new(text)
  end

  @[Scheme::SchemeFn("csv-write-headers", min: 2, max: 4)]
  def csv_write_headers(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    headers = csv_row_cells(args[0], "csv-write-headers").map { |header| string_arg(header, "csv-write-headers") }
    rows = csv_row_cells(args[1], "csv-write-headers").map { |row| csv_row_cells(row, "csv-write-headers") }
    sep = csv_separator_arg(args, 2, "csv-write-headers")
    quoting = csv_quoting_arg(args, 3, "csv-write-headers")
    text = String.build do |io|
      builder = Scheme::Csv::Builder.new(io, sep, quoting: quoting)
      builder.row(headers)
      rows.each { |row| csv_write_row(builder, row, "csv-write-headers") }
    end
    SchemeStr.new(text)
  end

  @[Scheme::SchemeFn("csv-writer-open", min: 1, max: 3)]
  def csv_writer_open(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    port = port_arg(args[0], "csv-writer-open")
    raise SchemeRuntimeError.new("csv-writer-open: expected an output port") unless port.output?
    sep = csv_separator_arg(args, 1, "csv-writer-open")
    quoting = csv_quoting_arg(args, 2, "csv-writer-open")
    SchemeBox.new("csv-writer", Scheme::Csv::Builder.new(port.io, sep, quoting: quoting), "#<csv-writer>")
  end

  @[Scheme::SchemeFn("csv-writer-row!", min: 1, max: -1)]
  def csv_writer_row(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    builder = csv_writer_arg(args[0], "csv-writer-row!")
    csv_write_row(builder, args[1..], "csv-writer-row!")
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("csv-writer?", min: 1, max: 1)]
  def csv_writer_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    SchemeBool.of(v.is_a?(SchemeBox) && v.tag == "csv-writer")
  end

  @[Scheme::SchemeFn("csv-reader-open", min: 1, max: 4)]
  def csv_reader_open(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    port = port_arg(args[0], "csv-reader-open")
    raise SchemeRuntimeError.new("csv-reader-open: expected an input port") unless port.input?
    sep = csv_separator_arg(args, 1, "csv-reader-open")
    quote = csv_quote_char_arg(args, 2, "csv-reader-open")
    chunk_size = csv_chunk_size_arg(args, 3, "csv-reader-open")
    SchemeBox.new("csv-reader", Scheme::Csv::Parser.new(port.io, sep, quote, chunk_size), "#<csv-reader>")
  end

  @[Scheme::SchemeFn("csv-reader-read!", min: 1, max: 1)]
  def csv_reader_read(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    parser = csv_reader_arg(args[0], "csv-reader-read!")
    cells = parser.next_row { |cell| SchemeStr.new(cell).as(SchemeValue) }
    return EOF.as(SchemeValue) unless cells
    SchemeVector.new(cells)
  rescue ex : Scheme::Csv::Error
    raise SchemeRuntimeError.new("csv-reader-read!: #{ex.message}")
  end

  @[Scheme::SchemeFn("csv-reader?", min: 1, max: 1)]
  def csv_reader_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    SchemeBool.of(v.is_a?(SchemeBox) && v.tag == "csv-reader")
  end

  private def csv_write_row(csv : Scheme::Csv::Builder, cells : Array(SchemeValue), who : String) : Nil
    csv.row do |row|
      cells.each { |cell| row << csv_cell_value(cell, who) }
    end
  end

  private def csv_cell_value(v : SchemeValue, who : String) : String | Bool | Int64 | Float64 | Nil
    case v
    when SchemeStr   then v.value
    when SchemeChar  then v.value.to_s
    when SchemeBool  then v.value?
    when SchemeInt   then v.value
    when SchemeFloat then v.value
    else
      raise SchemeRuntimeError.new("#{who}: cannot write cell #{v.write_string}")
    end
  end

  # A row (or the top-level list of rows) may be given as either a proper
  # list or a vector, matching how other creme modules accept sequences.
  private def csv_row_cells(v : SchemeValue, who : String) : Array(SchemeValue)
    return Scheme.list_to_a(v) if Scheme.proper_list?(v)
    return vector_arg(v, who) if v.is_a?(SchemeVector)
    raise SchemeRuntimeError.new("#{who}: expected a list or vector, got #{v.write_string}")
  end

  private def csv_separator_arg(args : Array(SchemeValue), index : Int32, who : String) : Char
    return ',' if args.size <= index
    csv_char_arg(args[index], who)
  end

  private def csv_quote_char_arg(args : Array(SchemeValue), index : Int32, who : String) : Char
    return '"' if args.size <= index
    csv_char_arg(args[index], who)
  end

  private def csv_chunk_size_arg(args : Array(SchemeValue), index : Int32, who : String) : Int32
    return Scheme::Csv::DEFAULT_CHUNK_SIZE if args.size <= index
    int_arg(args[index], who).to_i32
  end

  private def csv_char_arg(v : SchemeValue, who : String) : Char
    raise SchemeRuntimeError.new("#{who}: expected a character, got #{v.write_string}") unless v.is_a?(SchemeChar)
    v.value
  end

  private def csv_quoting_arg(args : Array(SchemeValue), index : Int32, who : String) : Scheme::Csv::Builder::Quoting
    return Scheme::Csv::Builder::Quoting::RFC if args.size <= index
    v = args[index]
    raise SchemeRuntimeError.new("#{who}: expected a quoting symbol, got #{v.write_string}") unless v.is_a?(SchemeSym)
    case v.name
    when "none" then Scheme::Csv::Builder::Quoting::NONE
    when "rfc"  then Scheme::Csv::Builder::Quoting::RFC
    when "all"  then Scheme::Csv::Builder::Quoting::ALL
    else
      raise SchemeRuntimeError.new("#{who}: unknown quoting mode '#{v.name}' (expected none, rfc, or all)")
    end
  end

  private def csv_writer_arg(v : SchemeValue, who : String) : Scheme::Csv::Builder
    raise SchemeRuntimeError.new("#{who}: expected a csv writer, got #{v.write_string}") unless v.is_a?(SchemeBox) && v.tag == "csv-writer"
    v.get(Scheme::Csv::Builder)
  end

  private def csv_reader_arg(v : SchemeValue, who : String) : Scheme::Csv::Parser
    raise SchemeRuntimeError.new("#{who}: expected a csv reader, got #{v.write_string}") unless v.is_a?(SchemeBox) && v.tag == "csv-reader"
    v.get(Scheme::Csv::Parser)
  end
end

module Scheme
  class Interpreter
    register_library ["creme", "csv"], Scheme::Builtins::CsvLibrary
  end
end
