# ===========================================================================
# (scheme char)
# ===========================================================================
#
# (scheme char) owns the character classification/case procedures and the
# case-insensitive char/string comparisons. Its export list is derived from
# register_module — no borrow list. (string-upcase/string-downcase/
# string-foldcase also live in (creme string); (scheme char) needs its own
# copies since it's not auto-imported from there. (scheme base) keeps the
# case-sensitive char=?/char<?/... and char->integer/integer->char.)

module Scheme::Builtins::CharLibrary
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("string-upcase", min: 1, max: 1)]
  def string_upcase(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeStr.new(string_ext_arg(args[0], "string-upcase").upcase)
  end

  @[Scheme::SchemeFn("string-downcase", min: 1, max: 1)]
  def string_downcase(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeStr.new(string_ext_arg(args[0], "string-downcase").downcase)
  end

  @[Scheme::SchemeFn("string-foldcase", min: 1, max: 1)]
  def string_foldcase(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeStr.new(string_ext_arg(args[0], "string-foldcase").downcase)
  end

  @[Scheme::SchemeFn("string-ci=?", min: 2, max: -1)]
  def string_ci_eq(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    string_chain_cmp(args, "string-ci=?") { |lhs, rhs| lhs.downcase == rhs.downcase }
  end

  @[Scheme::SchemeFn("string-ci<?", min: 2, max: -1)]
  def string_ci_lt(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    string_chain_cmp(args, "string-ci<?") { |lhs, rhs| lhs.downcase < rhs.downcase }
  end

  @[Scheme::SchemeFn("string-ci>?", min: 2, max: -1)]
  def string_ci_gt(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    string_chain_cmp(args, "string-ci>?") { |lhs, rhs| lhs.downcase > rhs.downcase }
  end

  @[Scheme::SchemeFn("string-ci<=?", min: 2, max: -1)]
  def string_ci_le(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    string_chain_cmp(args, "string-ci<=?") { |lhs, rhs| lhs.downcase <= rhs.downcase }
  end

  @[Scheme::SchemeFn("string-ci>=?", min: 2, max: -1)]
  def string_ci_ge(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    string_chain_cmp(args, "string-ci>=?") { |lhs, rhs| lhs.downcase >= rhs.downcase }
  end

  @[Scheme::SchemeFn("char-upcase", min: 1, max: 1)]
  def char_upcase(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeChar.new(char_arg(args[0], "char-upcase").upcase)
  end

  @[Scheme::SchemeFn("char-downcase", min: 1, max: 1)]
  def char_downcase(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeChar.new(char_arg(args[0], "char-downcase").downcase)
  end

  # foldcase is what case-insensitive comparisons use internally in a
  # full Unicode-aware implementation; here it's the same as downcase,
  # which is correct for the ASCII/simple-Unicode range this interpreter
  # otherwise handles.
  @[Scheme::SchemeFn("char-foldcase", min: 1, max: 1)]
  def char_foldcase(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeChar.new(char_arg(args[0], "char-foldcase").downcase)
  end

  @[Scheme::SchemeFn("digit-value", min: 1, max: 1)]
  def digit_value(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    c = char_arg(args[0], "digit-value")
    n = c.to_i?
    n ? SchemeInt.new(n.to_i64).as(SchemeValue) : FALSE.as(SchemeValue)
  end

  @[Scheme::SchemeFn("char-alphabetic?", min: 1, max: 1)]
  def char_alphabetic_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(char_arg(args[0], "char-alphabetic?").letter?)
  end

  @[Scheme::SchemeFn("char-numeric?", min: 1, max: 1)]
  def char_numeric_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(char_arg(args[0], "char-numeric?").number?)
  end

  @[Scheme::SchemeFn("char-whitespace?", min: 1, max: 1)]
  def char_whitespace_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(char_arg(args[0], "char-whitespace?").whitespace?)
  end

  @[Scheme::SchemeFn("char-upper-case?", min: 1, max: 1)]
  def char_upper_case_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(char_arg(args[0], "char-upper-case?").uppercase?)
  end

  @[Scheme::SchemeFn("char-lower-case?", min: 1, max: 1)]
  def char_lower_case_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(char_arg(args[0], "char-lower-case?").lowercase?)
  end

  @[Scheme::SchemeFn("char-ci=?", min: 2, max: -1)]
  def char_ci_eq(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    char_chain(args, "char-ci=?", true) { |lhs, rhs| lhs == rhs }
  end

  @[Scheme::SchemeFn("char-ci<?", min: 2, max: -1)]
  def char_ci_lt(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    char_chain(args, "char-ci<?", true) { |lhs, rhs| lhs < rhs }
  end

  @[Scheme::SchemeFn("char-ci>?", min: 2, max: -1)]
  def char_ci_gt(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    char_chain(args, "char-ci>?", true) { |lhs, rhs| lhs > rhs }
  end

  @[Scheme::SchemeFn("char-ci<=?", min: 2, max: -1)]
  def char_ci_le(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    char_chain(args, "char-ci<=?", true) { |lhs, rhs| lhs <= rhs }
  end

  @[Scheme::SchemeFn("char-ci>=?", min: 2, max: -1)]
  def char_ci_ge(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    char_chain(args, "char-ci>=?", true) { |lhs, rhs| lhs >= rhs }
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

  private def string_chain_cmp(args : Array(SchemeValue), who : String, &block : String, String -> Bool) : SchemeValue
    strs = args.map do |arg|
      raise SchemeRuntimeError.new("#{who}: expected string, got #{arg.write_string}") unless arg.is_a?(SchemeStr)
      arg.value
    end
    ok = (0...strs.size - 1).all? { |i| block.call(strs[i], strs[i + 1]) }
    SchemeBool.of(ok)
  end
end

module Scheme
  class Interpreter
    register_library ["scheme", "char"], Scheme::Builtins::CharLibrary
  end
end
