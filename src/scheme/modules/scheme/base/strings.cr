# ===========================================================================
# (scheme base): strings, chars, and numeric<->string conversion
# ===========================================================================
#
# The character classification/case procedures, the case-insensitive
# char-ci*/string-ci* comparisons, and string-foldcase live in (scheme char)
# (modules/scheme/char.cr). (scheme base) keeps the case-sensitive char=?/
# char<?/... comparisons and char->integer/integer->char.

module Scheme::Builtins::Strings
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("string-append", min: 0, max: -1)]
  def string_append(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    buf = String::Builder.new
    args.each do |arg|
      raise SchemeRuntimeError.new("string-append: expected string, got #{arg.write_string}") unless arg.is_a?(SchemeStr)
      buf << arg.value
    end
    SchemeStr.new(buf.to_s)
  end

  @[Scheme::SchemeFn("string-length", min: 1, max: 1)]
  def string_length(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    s = args[0]
    raise SchemeRuntimeError.new("string-length: expected string, got #{s.write_string}") unless s.is_a?(SchemeStr)
    SchemeInt.new(s.value.size.to_i64)
  end

  @[Scheme::SchemeFn("substring", min: 2, max: 3)]
  def substring(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    s = args[0]
    raise SchemeRuntimeError.new("substring: expected string, got #{s.write_string}") unless s.is_a?(SchemeStr)
    len = s.value.size.to_i64
    start64 = int_arg(args[1], "substring")
    endi64 = args.size == 3 ? int_arg(args[2], "substring") : len
    if start64 < 0 || endi64 > len || start64 > endi64
      raise SchemeRuntimeError.new("substring: index out of range")
    end
    SchemeStr.new(s.value[start64.to_i...endi64.to_i])
  end

  @[Scheme::SchemeFn("string->symbol", min: 1, max: 1)]
  def string_to_symbol(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    s = args[0]
    raise SchemeRuntimeError.new("string->symbol: expected string, got #{s.write_string}") unless s.is_a?(SchemeStr)
    SchemeSym.of(s.value)
  end

  @[Scheme::SchemeFn("symbol->string", min: 1, max: 1)]
  def symbol_to_string(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    s = args[0]
    raise SchemeRuntimeError.new("symbol->string: expected symbol, got #{s.write_string}") unless s.is_a?(SchemeSym)
    SchemeStr.new(s.name)
  end

  @[Scheme::SchemeFn("symbol=?", min: 2, max: -1)]
  def symbol_eq(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    first = args[0]
    raise SchemeRuntimeError.new("symbol=?: expected symbol, got #{first.write_string}") unless first.is_a?(SchemeSym)
    (1...args.size).each do |i|
      other = args[i]
      raise SchemeRuntimeError.new("symbol=?: expected symbol, got #{other.write_string}") unless other.is_a?(SchemeSym)
      return FALSE.as(SchemeValue) unless other.name == first.name
    end
    TRUE.as(SchemeValue)
  end

  @[Scheme::SchemeFn("boolean=?", min: 2, max: -1)]
  def boolean_eq(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    first = args[0]
    raise SchemeRuntimeError.new("boolean=?: expected boolean, got #{first.write_string}") unless first.is_a?(SchemeBool)
    (1...args.size).each do |i|
      other = args[i]
      raise SchemeRuntimeError.new("boolean=?: expected boolean, got #{other.write_string}") unless other.is_a?(SchemeBool)
      return FALSE.as(SchemeValue) unless other.value? == first.value?
    end
    TRUE.as(SchemeValue)
  end

  # radix (default 10) only applies to exact integers — R7RS leaves
  # non-decimal radix on inexact/non-integer numbers unspecified, so a
  # radix other than 10 is rejected for anything but a SchemeInt here.
  @[Scheme::SchemeFn("number->string", min: 1, max: 2)]
  def number_to_string(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    n = args[0]
    radix = radix_arg(args[1]?, "number->string")
    unless n.is_a?(SchemeInt) || n.is_a?(SchemeRational) || n.is_a?(SchemeFloat)
      raise SchemeRuntimeError.new("number->string: expected number, got #{n.write_string}")
    end
    if radix == 10
      SchemeStr.new(n.display_string)
    else
      raise SchemeRuntimeError.new("number->string: radix #{radix} requires an exact integer") unless n.is_a?(SchemeInt)
      SchemeStr.new(n.value.to_s(radix))
    end
  end

  @[Scheme::SchemeFn("string->number", min: 1, max: 2)]
  def string_to_number(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    s = args[0]
    radix = radix_arg(args[1]?, "string->number")
    raise SchemeRuntimeError.new("string->number: expected string, got #{s.write_string}") unless s.is_a?(SchemeStr)
    parse_number_string(s.value, radix)
  end

  @[Scheme::SchemeFn("string=?", min: 2, max: -1)]
  def string_eq(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    first = args[0]
    raise SchemeRuntimeError.new("string=?: expected string, got #{first.write_string}") unless first.is_a?(SchemeStr)
    (1...args.size).each do |i|
      s = args[i]
      raise SchemeRuntimeError.new("string=?: expected string, got #{s.write_string}") unless s.is_a?(SchemeStr)
      return FALSE.as(SchemeValue) unless s.value == first.value
    end
    TRUE.as(SchemeValue)
  end

  @[Scheme::SchemeFn("string<?", min: 2, max: -1)]
  def string_lt(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    string_chain_cmp(args, "string<?") { |lhs, rhs| lhs < rhs }
  end

  @[Scheme::SchemeFn("string>?", min: 2, max: -1)]
  def string_gt(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    string_chain_cmp(args, "string>?") { |lhs, rhs| lhs > rhs }
  end

  @[Scheme::SchemeFn("string<=?", min: 2, max: -1)]
  def string_le(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    string_chain_cmp(args, "string<=?") { |lhs, rhs| lhs <= rhs }
  end

  @[Scheme::SchemeFn("string>=?", min: 2, max: -1)]
  def string_ge(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    string_chain_cmp(args, "string>=?") { |lhs, rhs| lhs >= rhs }
  end

  @[Scheme::SchemeFn("string-ref", min: 2, max: 2)]
  def string_ref(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    s = args[0]
    raise SchemeRuntimeError.new("string-ref: expected string, got #{s.write_string}") unless s.is_a?(SchemeStr)
    idx = int_arg(args[1], "string-ref")
    raise SchemeRuntimeError.new("string-ref: index out of range") if idx < 0 || idx >= s.value.size
    SchemeChar.new(s.value[idx.to_i])
  end

  @[Scheme::SchemeFn("string->list", min: 1, max: 3)]
  def string_to_list(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    s = string_arg(args[0], "string->list")
    chars = s.chars
    first, last = seq_range_args(chars.size, args[1]?, args[2]?, "string->list")
    Scheme.a_to_list(chars[first...last].map { |chr| SchemeChar.new(chr).as(SchemeValue) })
  end

  @[Scheme::SchemeFn("list->string", min: 1, max: 1)]
  def list_to_string(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    buf = String::Builder.new
    Scheme.list_to_a(args[0]).each do |v|
      raise SchemeRuntimeError.new("list->string: expected list of chars, got #{v.write_string}") unless v.is_a?(SchemeChar)
      buf << v.value
    end
    SchemeStr.new(buf.to_s)
  end

  @[Scheme::SchemeFn("string", min: 0, max: -1)]
  def string(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    buf = String::Builder.new
    args.each do |v|
      raise SchemeRuntimeError.new("string: expected char, got #{v.write_string}") unless v.is_a?(SchemeChar)
      buf << v.value
    end
    SchemeStr.new(buf.to_s)
  end

  @[Scheme::SchemeFn("string-map", min: 2, max: -1)]
  def string_map(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    f = args[0]
    strings = args[1..].map { |v| string_arg(v, "string-map").chars }
    minlen = strings.min_of(&.size)
    buf = String::Builder.new
    minlen.times do |i|
      call_args = strings.map { |chars| SchemeChar.new(chars[i]).as(SchemeValue) }
      result = interp.apply(f, call_args)
      raise SchemeRuntimeError.new("string-map: expected the function to return a char") unless result.is_a?(SchemeChar)
      buf << result.value
    end
    SchemeStr.new(buf.to_s)
  end

  @[Scheme::SchemeFn("string-for-each", min: 2, max: -1)]
  def string_for_each(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    f = args[0]
    strings = args[1..].map { |v| string_arg(v, "string-for-each").chars }
    minlen = strings.min_of(&.size)
    minlen.times do |i|
      call_args = strings.map { |chars| SchemeChar.new(chars[i]).as(SchemeValue) }
      interp.apply(f, call_args)
    end
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("string-copy", min: 1, max: 3)]
  def string_copy(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    s = string_arg(args[0], "string-copy")
    first, last = seq_range_args(s.size, args[1]?, args[2]?, "string-copy")
    SchemeStr.new(s[first...last])
  end

  # (string-copy! to at from [start [end]]) copies from[start...end]
  # into to, starting at index `at`. Since Crystal strings are
  # immutable, this rebuilds `to`'s whole backing String rather than
  # mutating in place.
  @[Scheme::SchemeFn("string-copy!", min: 3, max: 5)]
  def string_copy_bang(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    to = args[0]
    raise SchemeRuntimeError.new("string-copy!: expected string, got #{to.write_string}") unless to.is_a?(SchemeStr)
    at = int_arg(args[1], "string-copy!").to_i32
    from = string_arg(args[2], "string-copy!")
    first, last = seq_range_args(from.size, args[3]?, args[4]?, "string-copy!")
    segment = from[first...last]
    to_chars = to.value.chars
    raise SchemeRuntimeError.new("string-copy!: destination range out of bounds") if at < 0 || at + segment.size > to_chars.size
    to_chars[at, segment.size] = segment.chars
    to.value = to_chars.join
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("string-set!", min: 3, max: 3)]
  def string_set(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    s = args[0]
    raise SchemeRuntimeError.new("string-set!: expected string, got #{s.write_string}") unless s.is_a?(SchemeStr)
    idx = int_arg(args[1], "string-set!").to_i32
    ch = args[2]
    raise SchemeRuntimeError.new("string-set!: expected char, got #{ch.write_string}") unless ch.is_a?(SchemeChar)
    chars = s.value.chars
    raise SchemeRuntimeError.new("string-set!: index out of range") if idx < 0 || idx >= chars.size
    chars[idx] = ch.value
    s.value = chars.join
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("string-fill!", min: 2, max: 4)]
  def string_fill(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    s = args[0]
    raise SchemeRuntimeError.new("string-fill!: expected string, got #{s.write_string}") unless s.is_a?(SchemeStr)
    fill = args[1]
    raise SchemeRuntimeError.new("string-fill!: expected char, got #{fill.write_string}") unless fill.is_a?(SchemeChar)
    chars = s.value.chars
    first, last = seq_range_args(chars.size, args[2]?, args[3]?, "string-fill!")
    (first...last).each { |i| chars[i] = fill.value }
    s.value = chars.join
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("string->vector", min: 1, max: 3)]
  def string_to_vector(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    s = string_arg(args[0], "string->vector")
    chars = s.chars
    first, last = seq_range_args(chars.size, args[1]?, args[2]?, "string->vector")
    SchemeVector.new(chars[first...last].map { |chr| SchemeChar.new(chr).as(SchemeValue) })
  end

  @[Scheme::SchemeFn("vector->string", min: 1, max: 3)]
  def vector_to_string(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    elems = vector_arg(args[0], "vector->string")
    first, last = seq_range_args(elems.size, args[1]?, args[2]?, "vector->string")
    buf = String::Builder.new
    elems[first...last].each do |v|
      raise SchemeRuntimeError.new("vector->string: expected vector of chars, got #{v.write_string}") unless v.is_a?(SchemeChar)
      buf << v.value
    end
    SchemeStr.new(buf.to_s)
  end

  @[Scheme::SchemeFn("make-string", min: 1, max: 2)]
  def make_string(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    len = int_arg(args[0], "make-string")
    raise SchemeRuntimeError.new("make-string: length must be non-negative") if len < 0
    fill = ' '
    if args.size == 2
      f = args[1]
      raise SchemeRuntimeError.new("make-string: expected char, got #{f.write_string}") unless f.is_a?(SchemeChar)
      fill = f.value
    end
    SchemeStr.new(fill.to_s * len)
  end

  @[Scheme::SchemeFn("char->integer", min: 1, max: 1)]
  def char_to_integer(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    c = args[0]
    raise SchemeRuntimeError.new("char->integer: expected char, got #{c.write_string}") unless c.is_a?(SchemeChar)
    SchemeInt.new(c.value.ord.to_i64)
  end

  @[Scheme::SchemeFn("integer->char", min: 1, max: 1)]
  def integer_to_char(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    n = int_arg(args[0], "integer->char")
    raise SchemeRuntimeError.new("integer->char: code point out of range") if n < 0 || n > 0x10FFFF
    SchemeChar.new(n.to_i32.chr)
  end

  @[Scheme::SchemeFn("char=?", min: 2, max: -1)]
  def char_eq(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    char_chain(args, "char=?", false) { |lhs, rhs| lhs == rhs }
  end

  @[Scheme::SchemeFn("char<?", min: 2, max: -1)]
  def char_lt(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    char_chain(args, "char<?", false) { |lhs, rhs| lhs < rhs }
  end

  @[Scheme::SchemeFn("char>?", min: 2, max: -1)]
  def char_gt(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    char_chain(args, "char>?", false) { |lhs, rhs| lhs > rhs }
  end

  @[Scheme::SchemeFn("char<=?", min: 2, max: -1)]
  def char_le(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    char_chain(args, "char<=?", false) { |lhs, rhs| lhs <= rhs }
  end

  @[Scheme::SchemeFn("char>=?", min: 2, max: -1)]
  def char_ge(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    char_chain(args, "char>=?", false) { |lhs, rhs| lhs >= rhs }
  end

  private def string_chain_cmp(args : Array(SchemeValue), who : String, &block : String, String -> Bool) : SchemeValue
    strs = args.map do |arg|
      raise SchemeRuntimeError.new("#{who}: expected string, got #{arg.write_string}") unless arg.is_a?(SchemeStr)
      arg.value
    end
    ok = (0...strs.size - 1).all? { |i| block.call(strs[i], strs[i + 1]) }
    SchemeBool.of(ok)
  end

  private def parse_number_string(txt : String, radix : Int32) : SchemeValue
    if radix != 10
      begin
        return SchemeInt.new(txt.to_i64(radix)).as(SchemeValue)
      rescue ArgumentError
        return FALSE.as(SchemeValue)
      end
    end
    if Lexer::INT_RE.matches?(txt) && (parsed_int = txt.to_i64?)
      return SchemeInt.new(parsed_int).as(SchemeValue)
    end
    is_float_syntax = txt.includes?('.') || txt.includes?('e') || txt.includes?('E')
    if Lexer::FLOAT_RE.matches?(txt) && is_float_syntax && (parsed_float = txt.to_f64?)
      return SchemeFloat.new(parsed_float).as(SchemeValue)
    end
    FALSE.as(SchemeValue)
  end

  private def char_arg(v : SchemeValue, who : String) : Char
    raise SchemeRuntimeError.new("#{who}: expected char, got #{v.write_string}") unless v.is_a?(SchemeChar)
    v.value
  end

  private def char_chain(args : Array(SchemeValue), who : String, case_insensitive : Bool, &cmp : Char, Char -> Bool) : SchemeValue
    (0...args.size - 1).each do |i|
      a = char_arg(args[i], who)
      b = char_arg(args[i + 1], who)
      a, b = a.downcase, b.downcase if case_insensitive
      return FALSE.as(SchemeValue) unless cmp.call(a, b)
    end
    TRUE.as(SchemeValue)
  end
end

module Scheme
  class Interpreter
    private def install_strings(env : Env) : Array(String)
      register_module(Scheme::Builtins::Strings, env)
    end
  end
end
