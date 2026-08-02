# ===========================================================================
# regex module: pattern matching on strings (SRFI-115 naming)
# ===========================================================================

module Scheme::Builtins::RegexLibrary
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("regexp", min: 1, max: 1)]
  def regexp(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    pat = regex_str_arg(args[0], "regexp")
    SchemeBox.new("regex", Regex.new(pat), "#<regex:#{pat}>")
  rescue ex : Exception
    raise SchemeRuntimeError.new("regexp: invalid pattern '#{pat}': #{ex.message}")
  end

  @[Scheme::SchemeFn("regexp-matches?", min: 2, max: 2)]
  def regexp_matches_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    rx = regex_arg(args[0], "regexp-matches?")
    s = regex_str_arg(args[1], "regexp-matches?")
    SchemeBool.of(rx.matches?(s))
  end

  @[Scheme::SchemeFn("regexp-search", min: 2, max: 2)]
  def regexp_search(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    rx = regex_arg(args[0], "regexp-search")
    s = regex_str_arg(args[1], "regexp-search")
    if found = rx.match(s)
      Scheme.a_to_list(found.to_a.map { |group| group ? SchemeStr.new(group).as(SchemeValue) : FALSE.as(SchemeValue) })
    else
      FALSE.as(SchemeValue)
    end
  end

  @[Scheme::SchemeFn("regexp-extract", min: 2, max: 2)]
  def regexp_extract(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    rx = regex_arg(args[0], "regexp-extract")
    s = regex_str_arg(args[1], "regexp-extract")
    matches = [] of SchemeValue
    s.scan(rx) do |found|
      matches << Scheme.a_to_list(found.to_a.map { |group| group ? SchemeStr.new(group).as(SchemeValue) : FALSE.as(SchemeValue) })
    end
    Scheme.a_to_list(matches)
  end

  @[Scheme::SchemeFn("regexp-replace", min: 3, max: 3)]
  def regexp_replace(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    rx = regex_arg(args[0], "regexp-replace")
    rep = regex_str_arg(args[1], "regexp-replace")
    s = regex_str_arg(args[2], "regexp-replace")
    SchemeStr.new(s.sub(rx, rep))
  end

  @[Scheme::SchemeFn("regexp-replace-all", min: 3, max: 3)]
  def regexp_replace_all(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    rx = regex_arg(args[0], "regexp-replace-all")
    rep = regex_str_arg(args[1], "regexp-replace-all")
    s = regex_str_arg(args[2], "regexp-replace-all")
    SchemeStr.new(s.gsub(rx, rep))
  end

  @[Scheme::SchemeFn("regexp-split", min: 2, max: 2)]
  def regexp_split(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    rx = regex_arg(args[0], "regexp-split")
    s = regex_str_arg(args[1], "regexp-split")
    Scheme.a_to_list(s.split(rx).map { |x| SchemeStr.new(x).as(SchemeValue) })
  end

  @[Scheme::SchemeFn("regexp?", min: 1, max: 1)]
  def regexp_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    SchemeBool.of(v.is_a?(SchemeBox) && v.tag == "regex")
  end

  private def regex_arg(v : SchemeValue, who : String) : Regex
    raise SchemeRuntimeError.new("#{who}: expected regex, got #{v.write_string}") unless v.is_a?(SchemeBox) && v.tag == "regex"
    v.get(Regex)
  end

  private def regex_str_arg(v : SchemeValue, who : String) : String
    raise SchemeRuntimeError.new("#{who}: expected string, got #{v.write_string}") unless v.is_a?(SchemeStr)
    v.value
  end
end

module Scheme
  class Interpreter
    register_library ["creme", "builtin", "regex"], Scheme::Builtins::RegexLibrary
  end
end
