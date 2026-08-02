require "../../../spec_helper"
require "csv"

# Adapted from Crystal stdlib's own spec/std/csv/{csv,csv_parse,csv_lex,csv_build}_spec.cr
# (crystal-lang/crystal, tag v1.20.3) via the vendored `lib/fastcsv` fork this
# project used to depend on -- Creme::Csv (src/creme/modules/creme/csv.cr)
# replaced that vendored dependency with a self-contained port, so this file
# is the same correctness suite retargeted at Creme::Csv directly (a pure
# Crystal spec, no Scheme interpreter involved) rather than testing a
# separate shard.
#
# NOT ported: stdlib's two IO-consumption-granularity regression specs
# ("doesn't consume char after \n"/"\r", crystal-lang/crystal#11172), which
# assert `io.pos` immediately after lexing just one token. Those encode a
# deliberate stdlib property -- read from the IO no further than the
# current token strictly requires -- that Lexer::IOBased intentionally
# gives up: it reads in large chunks (see its own comment) for raw speed,
# so `io.pos` jumps ahead to (up to) a whole chunk boundary rather than
# advancing one token at a time. Fine for every real caller in this
# project (a parser always owns its IO for its whole lifetime, never
# interleaved with unrelated reads on the same IO), called out explicitly
# rather than silently dropped.
private def new_parser(string_or_io, separator = Creme::Csv::DEFAULT_SEPARATOR, quote_char = Creme::Csv::DEFAULT_QUOTE_CHAR,
                       chunk_size = Creme::Csv::DEFAULT_CHUNK_SIZE)
  Creme::Csv::Parser.new(string_or_io, separator, quote_char, chunk_size)
end

private def parse(string_or_io, separator = Creme::Csv::DEFAULT_SEPARATOR, quote_char = Creme::Csv::DEFAULT_QUOTE_CHAR)
  rows = [] of Array(String)
  parser = new_parser(string_or_io, separator, quote_char)
  while row = parser.next_row
    rows << row
  end
  rows
end

private def build(separator = Creme::Csv::DEFAULT_SEPARATOR, quote_char = Creme::Csv::DEFAULT_QUOTE_CHAR,
                  quoting = Creme::Csv::Builder::Quoting::RFC, &)
  String.build do |io|
    builder = Creme::Csv::Builder.new(io, separator, quote_char, quoting)
    yield builder
  end
end

# An IO wrapper that hands back at most one byte per `read` call,
# regardless of how much of the underlying IO's data is available -- used
# to exercise the short-read path a real, buffered `File` sometimes takes
# (returning fewer bytes than requested even when more data remains) but
# `IO::Memory` never does on its own (it always fills the given slice
# greedily when enough data is buffered).
private class OneByteIO < IO
  def initialize(@inner : IO)
  end

  def read(slice : Bytes) : Int32
    return 0 if slice.empty?
    @inner.read(slice[0, 1])
  end

  def write(slice : Bytes) : Nil
    raise "not supported"
  end
end

describe Creme::Csv do
  describe "parse" do
    it "parses empty string" do
      parse("").should eq([] of String)
    end

    it "parses one simple row" do
      parse("hello,world").should eq([["hello", "world"]])
    end

    it "parses one row with spaces" do
      parse("   hello   ,   world  ").should eq([["   hello   ", "   world  "]])
    end

    it "parses two rows" do
      parse("hello,world\ngood,bye").should eq([
        ["hello", "world"],
        ["good", "bye"],
      ])
    end

    it "parses two rows with the last one having a newline" do
      parse("hello,world\ngood,bye\n").should eq([
        ["hello", "world"],
        ["good", "bye"],
      ])
    end

    it "parses with quote" do
      parse(%("hello","world")).should eq([["hello", "world"]])
    end

    it "parses with quote and newline" do
      parse(%("hello","world"\nfoo)).should eq([["hello", "world"], ["foo"]])
    end

    it "parses with double quote" do
      parse(%("hel""lo","wor""ld")).should eq([[%(hel"lo), %(wor"ld)]])
    end

    it "parses some commas" do
      parse(%(,,)).should eq([["", "", ""]])
    end

    it "parses empty quoted string" do
      parse(%("","")).should eq([["", ""]])
    end

    it "raises if single quote in the middle" do
      expect_raises Creme::Csv::MalformedError, "Unexpected quote at line 1, column 4" do
        parse(%(hel"lo))
      end
    end

    it "raises if command, newline or end doesn't follow quote" do
      expect_raises Creme::Csv::MalformedError, "Expecting comma, newline or end, not 'a' at line 2, column 6" do
        parse(%(foo\n"hel"a))
      end
    end

    it "parses from IO" do
      parse(IO::Memory.new(%("hel""lo",world))).should eq([[%(hel"lo), %(world)]])
    end

    it "takes an optional separator argument" do
      parse("foo;bar", separator: ';').should eq([["foo", "bar"]])
    end

    it "takes an optional quote char argument" do
      parse("'foo,bar'", quote_char: '\'').should eq([["foo,bar"]])
    end
  end

  it "parses row by row" do
    parser = new_parser("hello,world\ngood,bye\n")
    parser.next_row.should eq(%w(hello world))
    parser.next_row.should eq(%w(good bye))
    parser.next_row.should be_nil
  end

  describe "lex" do
    it "lexes two columns" do
      lexer = Creme::Csv::Lexer.new("hello,world")
      expect_cell(lexer, "hello")
      expect_cell(lexer, "world")
      expect_eof(lexer)
    end

    it "lexes two columns with two rows" do
      lexer = Creme::Csv::Lexer.new("hello,world\nfoo,bar")
      expect_cell(lexer, "hello")
      expect_cell(lexer, "world")
      expect_newline(lexer)
      expect_cell(lexer, "foo")
      expect_cell(lexer, "bar")
      expect_eof(lexer)
    end

    it "lexes two columns with two rows with \r\n" do
      lexer = Creme::Csv::Lexer.new("hello,world\r\nfoo,bar")
      expect_cell(lexer, "hello")
      expect_cell(lexer, "world")
      expect_newline(lexer)
      expect_cell(lexer, "foo")
      expect_cell(lexer, "bar")
      expect_eof(lexer)
    end

    it "lexes two empty columns" do
      lexer = Creme::Csv::Lexer.new(",")
      expect_cell(lexer, "")
      expect_cell(lexer, "")
      expect_eof(lexer)
    end

    it "lexes last empty column" do
      lexer = Creme::Csv::Lexer.new("foo,")
      expect_cell(lexer, "foo")
      expect_cell(lexer, "")
      expect_eof(lexer)
    end

    it "lexes with empty columns" do
      lexer = Creme::Csv::Lexer.new("foo,,bar")
      expect_cell(lexer, "foo")
      expect_cell(lexer, "")
      expect_cell(lexer, "bar")
      expect_eof(lexer)
    end

    it "lexes with whitespace" do
      lexer = Creme::Csv::Lexer.new("  foo  ,  bar  ")
      expect_cell(lexer, "  foo  ")
      expect_cell(lexer, "  bar  ")
      expect_eof(lexer)
    end

    it "lexes two with quotes" do
      lexer = Creme::Csv::Lexer.new(%("hello","world"))
      expect_cell(lexer, "hello")
      expect_cell(lexer, "world")
      expect_eof(lexer)
    end

    it "lexes two with inner quotes" do
      lexer = Creme::Csv::Lexer.new(%("hel""lo","wor""ld"))
      expect_cell(lexer, %(hel"lo))
      expect_cell(lexer, %(wor"ld))
      expect_eof(lexer)
    end

    it "lexes with comma inside quote" do
      lexer = Creme::Csv::Lexer.new(%("foo,bar"))
      expect_cell(lexer, "foo,bar")
      expect_eof(lexer)
    end

    it "lexes with newline inside quote" do
      lexer = Creme::Csv::Lexer.new(%("foo\nbar"))
      expect_cell(lexer, "foo\nbar")
      expect_eof(lexer)
    end

    it "lexes newline followed by eof" do
      lexer = Creme::Csv::Lexer.new("hello,world\n")
      expect_cell(lexer, "hello")
      expect_cell(lexer, "world")
      expect_newline(lexer)
      expect_eof(lexer)
    end

    it "lexes with a given separator" do
      lexer = Creme::Csv::Lexer.new("hello;world\n", separator: ';')
      expect_cell(lexer, "hello")
      expect_cell(lexer, "world")
      expect_newline(lexer)
      expect_eof(lexer)
    end

    it "lexes with a given quote char" do
      lexer = Creme::Csv::Lexer.new("'hello,world'\n", quote_char: '\'')
      expect_cell(lexer, "hello,world")
      expect_newline(lexer)
      expect_eof(lexer)
    end

    it "raises if single quote in the middle" do
      expect_raises Creme::Csv::MalformedError, "Unexpected quote at line 1, column 4" do
        lexer = Creme::Csv::Lexer.new %(hel"lo)
        lexer.next_token
      end
    end

    it "raises if command, newline or end doesn't follow quote" do
      expect_raises Creme::Csv::MalformedError, "Expecting comma, newline or end, not 'a' at line 1, column 6" do
        lexer = Creme::Csv::Lexer.new %("hel"a)
        lexer.next_token
      end
    end

    it "raises on unclosed quote" do
      expect_raises Creme::Csv::MalformedError, "Unclosed quote at line 1, column 5" do
        lexer = Creme::Csv::Lexer.new %("foo)
        lexer.next_token
      end
    end
  end

  describe "build" do
    it "builds two rows" do
      build { |csv|
        csv.row { |row| row << "one"; row << "two" }
        csv.row { |row| row << "three"; row << "four" }
      }.should eq("one,two\nthree,four\n")
    end

    it "builds with numbers" do
      build { |csv|
        csv.row { |row| row << 1; row << 2 }
        csv.row { |row| row << 3; row << 4 }
      }.should eq("1,2\n3,4\n")
    end

    it "builds with commas" do
      build { |csv| csv.row { |row| row << %(hello,world) } }.should eq(%("hello,world"\n))
    end

    it "builds with custom separator" do
      build(separator: ';') { |csv|
        csv.row { |row| row << "one"; row << "two"; row << "thr;ee" }
      }.should eq(%(one;two;"thr;ee"\n))
    end

    it "builds with quotes" do
      build { |csv| csv.row { |row| row << %(he said "no") } }.should eq(%("he said ""no"""\n))
    end

    it "builds with custom quote character" do
      build(quote_char: '\'') { |csv|
        csv.row { |row| row << %(he said 'no') }
      }.should eq(%('he said ''no'''\n))
    end

    it "builds row from enumerable" do
      build(&.row([1, 2, 3])).should eq("1,2,3\n")
    end

    it "builds with quoting" do
      build(quoting: Creme::Csv::Builder::Quoting::NONE) { |csv|
        csv.row 1, "doesn't", " , ", %(he said "no")
      }.should eq(%(1,doesn't, , ,he said "no"\n))

      build(quoting: Creme::Csv::Builder::Quoting::RFC) { |csv|
        csv.row 1, "doesn't", " , ", %(he said "no")
      }.should eq(%(1,doesn't," , ","he said ""no"""\n))

      build(quoting: Creme::Csv::Builder::Quoting::ALL) { |csv|
        csv.row 1, "doesn't", " , ", %(he said "no")
      }.should eq(%("1","doesn't"," , ","he said ""no"""\n))
    end
  end

  # --- chunk-boundary correctness ---------------------------------------
  #
  # The whole point of IOBased's chunked design is reading in
  # DEFAULT_CHUNK_SIZE-sized (65536-char) pieces -- these exercise the
  # refill path directly, which none of the tiny-string specs above ever
  # touch.

  chunk_size = Creme::Csv::DEFAULT_CHUNK_SIZE

  it "parses a quoted cell whose content straddles a chunk boundary" do
    # Padding placed so the opening quote lands a few chars before the
    # boundary and the closing quote lands a few chars after it.
    prefix = "a" * (chunk_size - 5)
    inner = "b" * 20
    csv = %(#{prefix},"#{inner}",tail)
    parse(IO::Memory.new(csv)).should eq([[prefix, inner, "tail"]])
  end

  it "parses an unquoted cell whose content straddles a chunk boundary" do
    prefix = "x" * (chunk_size - 10)
    csv = "start,#{prefix}yz,end"
    parse(IO::Memory.new(csv)).should eq([["start", "#{prefix}yz", "end"]])
  end

  it "parses a multi-byte UTF-8 character positioned right at a chunk boundary" do
    # A 3-byte character (é is 2 bytes; use a genuinely 3-byte one) placed
    # so it would be split across the chunk_size byte boundary if chunking
    # were done on raw bytes instead of UTF-8-safe semantics.
    three_byte_char = "€" # U+20AC, 3 bytes in UTF-8
    prefix = "a" * (chunk_size - 1)
    csv = "#{prefix}#{three_byte_char},tail"
    parse(IO::Memory.new(csv)).should eq([["#{prefix}#{three_byte_char}", "tail"]])
  end

  it "supports a configurable chunk_size, exercising the refill path on a tiny buffer" do
    csv = "one,two\nthree,four\nfive,six"
    parser = new_parser(IO::Memory.new(csv), chunk_size: 4)
    rows = [] of Array(String)
    while row = parser.next_row
      rows << row
    end
    rows.should eq([%w(one two), %w(three four), %w(five six)])
  end

  # Regression: `IO#read` is only obligated to return AT LEAST ONE byte
  # when more data remains, not to fill the whole slice given to it --
  # `IO::Memory` always fills greedily, so it can never exercise a `read`
  # call returning e.g. exactly 1 byte (a lone UTF-8 leader byte, its
  # continuation byte(s) still unread). A real `File`'s buffered reads DO
  # sometimes hand back short reads like this, and a small chunk_size
  # makes hitting one mid-multi-byte-character far more likely.
  # `fill_buffer` used to treat "0 usable bytes decoded so far" as if it
  # were true EOF, since a Char::Reader over an empty string reads its
  # current char as the same null sentinel true EOF uses.
  it "doesn't truncate a cell when a single read() call returns exactly one byte of a multi-byte UTF-8 leader" do
    one_byte_at_a_time = IO::Memory.new("Antípodas\t1857\t1\t1\nAntípodas\t1969\t1\t1\n")
    parser = new_parser(OneByteIO.new(one_byte_at_a_time), separator: '\t', quote_char: '\0', chunk_size: 8)
    rows = [] of Array(String)
    while row = parser.next_row
      rows << row
    end
    rows.should eq([
      %w(Antípodas 1857 1 1),
      %w(Antípodas 1969 1 1),
    ])
  end

  it "matches stdlib CSV.parse row-for-row on a large generated file crossing many chunk boundaries" do
    io = IO::Memory.new
    500.times do |i|
      io << i << "," << "word#{i}" << "," << %("quoted, value #{i}") << "," << ("z" * (i % 50)) << '\n'
    end
    text = io.to_s
    parse(IO::Memory.new(text)).should eq(CSV.parse(text))
  end

  it "matches stdlib CSV.parse on real tab-separated data with no quoting" do
    io = IO::Memory.new
    200.times { |i| io << "word#{i}" << '\t' << (1900 + i) << '\t' << i << '\n' }
    text = io.to_s
    parse(IO::Memory.new(text), separator: '\t').should eq(CSV.parse(text, separator: '\t'))
  end
end

private def expect_cell(lexer, value, file = __FILE__, line = __LINE__)
  token = lexer.next_token
  token.kind.should eq(Creme::Csv::Token::Kind::Cell), file: file, line: line
  token.value.should eq(value), file: file, line: line
end

private def expect_eof(lexer, file = __FILE__, line = __LINE__)
  lexer.next_token.kind.should eq(Creme::Csv::Token::Kind::Eof), file: file, line: line
end

private def expect_newline(lexer, file = __FILE__, line = __LINE__)
  lexer.next_token.kind.should eq(Creme::Csv::Token::Kind::Newline), file: file, line: line
end
