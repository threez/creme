# ===========================================================================
# string module: extended string operations (core unqualified builtins
# already provide string-append, string-length, substring, etc.)
# ===========================================================================

module Creme::Builtins::StringLibrary
  extend self
  include Creme::BuiltinHelpers

  @[Creme::SchemeFn("string-upcase", min: 1, max: 1)]
  def string_upcase(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeStr.new(string_ext_arg(args[0], "string-upcase").upcase)
  end

  @[Creme::SchemeFn("string-downcase", min: 1, max: 1)]
  def string_downcase(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeStr.new(string_ext_arg(args[0], "string-downcase").downcase)
  end

  @[Creme::SchemeFn("string-trim", min: 1, max: 1)]
  def string_trim(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeStr.new(string_ext_arg(args[0], "string-trim").strip)
  end

  @[Creme::SchemeFn("string-reverse", min: 1, max: 1)]
  def string_reverse(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeStr.new(string_ext_arg(args[0], "string-reverse").reverse)
  end

  @[Creme::SchemeFn("string-split", min: 2, max: 2)]
  def string_split(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    s = string_ext_arg(args[0], "string-split")
    sep = string_ext_arg(args[1], "string-split")
    Creme.a_to_list(s.split(sep).map { |x| SchemeStr.new(x).as(SchemeValue) })
  end

  @[Creme::SchemeFn("string-join", min: 2, max: 2)]
  def string_join(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    elems = Creme.list_to_a(args[0])
    sep = string_ext_arg(args[1], "string-join")
    strs = elems.map do |e|
      raise SchemeRuntimeError.new("string-join: expected list of strings, got #{e.write_string}") unless e.is_a?(SchemeStr)
      e.value
    end
    SchemeStr.new(strs.join(sep))
  end

  @[Creme::SchemeFn("string-replace", min: 3, max: 3)]
  def string_replace(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    s = string_ext_arg(args[0], "string-replace")
    from = string_ext_arg(args[1], "string-replace")
    to = string_ext_arg(args[2], "string-replace")
    SchemeStr.new(s.gsub(from, to))
  end

  # (string-translate s pairs) -> s with every occurrence of each pairs'
  # char replaced by its paired string, all substitutions found in a
  # SINGLE native pass over s (Crystal's String#gsub(Hash(Char, String))) --
  # unlike chaining N string-replace calls (each its own full O(n) native
  # scan/copy), this scans/copies s once regardless of how many
  # replacements pairs holds. pairs is an alist of (char . string), e.g.
  # '((#\& . "&amp;") (#\< . "&lt;")).
  @[Creme::SchemeFn("string-translate", min: 2, max: 2)]
  def string_translate(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    s = string_ext_arg(args[0], "string-translate")
    table = {} of Char => String
    Creme.list_to_a(args[1]).each do |pair|
      raise SchemeRuntimeError.new("string-translate: expected an alist of (char . string)") unless pair.is_a?(Cons)
      key = pair.car
      val = pair.cdr
      raise SchemeRuntimeError.new("string-translate: expected an alist of (char . string)") unless key.is_a?(SchemeChar) && val.is_a?(SchemeStr)
      table[key.value] = val.value
    end
    SchemeStr.new(s.gsub(table))
  end

  @[Creme::SchemeFn("string-contains?", min: 2, max: 2)]
  def string_contains_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(string_ext_arg(args[0], "string-contains?").includes?(string_ext_arg(args[1], "string-contains?")))
  end

  @[Creme::SchemeFn("string-prefix?", min: 2, max: 2)]
  def string_prefix_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(string_ext_arg(args[0], "string-prefix?").starts_with?(string_ext_arg(args[1], "string-prefix?")))
  end

  @[Creme::SchemeFn("string-suffix?", min: 2, max: 2)]
  def string_suffix_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(string_ext_arg(args[0], "string-suffix?").ends_with?(string_ext_arg(args[1], "string-suffix?")))
  end

  @[Creme::SchemeFn("string-index-of", min: 2, max: 2)]
  def string_index_of(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    s = string_ext_arg(args[0], "string-index-of")
    needle = string_ext_arg(args[1], "string-index-of")
    idx = s.index(needle)
    idx ? SchemeInt.new(idx.to_i64).as(SchemeValue) : FALSE.as(SchemeValue)
  end

  @[Creme::SchemeFn("string-repeat", min: 2, max: 2)]
  def string_repeat(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    s = string_ext_arg(args[0], "string-repeat")
    n = args[1]
    raise SchemeRuntimeError.new("string-repeat: expected integer, got #{n.write_string}") unless n.is_a?(SchemeInt)
    raise SchemeRuntimeError.new("string-repeat: count must be non-negative") if n.value < 0
    SchemeStr.new(s * n.value)
  end

  @[Creme::SchemeFn("string-pad", min: 3, max: 3)]
  def string_pad(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    s = string_ext_arg(args[0], "string-pad")
    len = args[1]
    pad = string_ext_arg(args[2], "string-pad")
    raise SchemeRuntimeError.new("string-pad: expected integer, got #{len.write_string}") unless len.is_a?(SchemeInt)
    raise SchemeRuntimeError.new("string-pad: pad string must be exactly 1 char") unless pad.size == 1
    SchemeStr.new(s.rjust(len.value.to_i, pad[0]))
  end

  @[Creme::SchemeFn("string-pad-right", min: 3, max: 3)]
  def string_pad_right(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    s = string_ext_arg(args[0], "string-pad-right")
    len = args[1]
    pad = string_ext_arg(args[2], "string-pad-right")
    raise SchemeRuntimeError.new("string-pad-right: expected integer, got #{len.write_string}") unless len.is_a?(SchemeInt)
    raise SchemeRuntimeError.new("string-pad-right: pad string must be exactly 1 char") unless pad.size == 1
    SchemeStr.new(s.ljust(len.value.to_i, pad[0]))
  end
end

module Creme
  class Interpreter
    register_library ["creme", "builtin", "string"], Creme::Builtins::StringLibrary
  end
end
