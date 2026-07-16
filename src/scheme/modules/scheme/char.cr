# ===========================================================================
# (scheme char)
# ===========================================================================

module Scheme::Builtins::CharLibrary
  extend self
  include Scheme::BuiltinHelpers

  # string-upcase/downcase live in (creme string) too; (scheme char) needs
  # its own copy since it's not auto-imported from there.
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
end

module Scheme
  class Interpreter
    register_library ["scheme", "char"] do |env|
      own = register_module(Scheme::Builtins::CharLibrary, env)
      borrowed = %w[char-alphabetic? char-ci<=? char-ci<? char-ci=? char-ci>=? char-ci>? char-downcase char-foldcase
        char-lower-case? char-numeric? char-upcase char-upper-case? char-whitespace? digit-value
        string-ci<=? string-ci<? string-ci=? string-ci>=? string-ci>?]
      borrowed.each do |name|
        env.define(name, @base_env.get(name))
      end
      own + borrowed
    end
  end
end
