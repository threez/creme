# ===========================================================================
# (scheme cxr)
# ===========================================================================
#
# The 24 car/cdr compositions R7RS Appendix A scopes to (scheme cxr): every
# 3- and 4-level composition, including caddr/cdddr/cadddr — confirmed
# against the spec text (only the four 2-level compositions, caar/cadr/
# cdar/cddr, are (scheme base) exports). prelude.cr still defines
# caddr/cdddr/cadddr directly in @base_env for backward compatibility with
# existing unprefixed usage — this installer additionally exposes them (and
# the other 21) through the real (scheme cxr) library for code that imports
# properly.

module Creme::R7RS::Cxr
  extend self
  include Creme::BuiltinHelpers

  @[Creme::SchemeFn("caaaar", min: 1, max: 1)]
  def caaaar(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("caaaar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("caaaar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("caaaar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("caaaar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    v
  end

  @[Creme::SchemeFn("caaadr", min: 1, max: 1)]
  def caaadr(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("caaadr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("caaadr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("caaadr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("caaadr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    v
  end

  @[Creme::SchemeFn("caaar", min: 1, max: 1)]
  def caaar(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("caaar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("caaar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("caaar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    v
  end

  @[Creme::SchemeFn("caadar", min: 1, max: 1)]
  def caadar(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("caadar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("caadar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("caadar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("caadar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    v
  end

  @[Creme::SchemeFn("caaddr", min: 1, max: 1)]
  def caaddr(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("caaddr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("caaddr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("caaddr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("caaddr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    v
  end

  @[Creme::SchemeFn("caadr", min: 1, max: 1)]
  def caadr(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("caadr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("caadr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("caadr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    v
  end

  @[Creme::SchemeFn("cadaar", min: 1, max: 1)]
  def cadaar(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("cadaar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("cadaar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("cadaar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("cadaar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    v
  end

  @[Creme::SchemeFn("cadadr", min: 1, max: 1)]
  def cadadr(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("cadadr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("cadadr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("cadadr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("cadadr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    v
  end

  @[Creme::SchemeFn("cadar", min: 1, max: 1)]
  def cadar(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("cadar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("cadar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("cadar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    v
  end

  @[Creme::SchemeFn("caddar", min: 1, max: 1)]
  def caddar(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("caddar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("caddar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("caddar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("caddar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    v
  end

  @[Creme::SchemeFn("cadddr", min: 1, max: 1)]
  def cadddr(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("cadddr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("cadddr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("cadddr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("cadddr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    v
  end

  @[Creme::SchemeFn("caddr", min: 1, max: 1)]
  def caddr(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("caddr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("caddr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("caddr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    v
  end

  @[Creme::SchemeFn("cdaaar", min: 1, max: 1)]
  def cdaaar(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("cdaaar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("cdaaar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("cdaaar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("cdaaar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    v
  end

  @[Creme::SchemeFn("cdaadr", min: 1, max: 1)]
  def cdaadr(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("cdaadr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("cdaadr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("cdaadr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("cdaadr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    v
  end

  @[Creme::SchemeFn("cdaar", min: 1, max: 1)]
  def cdaar(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("cdaar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("cdaar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("cdaar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    v
  end

  @[Creme::SchemeFn("cdadar", min: 1, max: 1)]
  def cdadar(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("cdadar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("cdadar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("cdadar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("cdadar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    v
  end

  @[Creme::SchemeFn("cdaddr", min: 1, max: 1)]
  def cdaddr(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("cdaddr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("cdaddr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("cdaddr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("cdaddr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    v
  end

  @[Creme::SchemeFn("cdadr", min: 1, max: 1)]
  def cdadr(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("cdadr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("cdadr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("cdadr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    v
  end

  @[Creme::SchemeFn("cddaar", min: 1, max: 1)]
  def cddaar(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("cddaar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("cddaar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("cddaar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("cddaar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    v
  end

  @[Creme::SchemeFn("cddadr", min: 1, max: 1)]
  def cddadr(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("cddadr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("cddadr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("cddadr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("cddadr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    v
  end

  @[Creme::SchemeFn("cddar", min: 1, max: 1)]
  def cddar(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("cddar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("cddar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("cddar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    v
  end

  @[Creme::SchemeFn("cdddar", min: 1, max: 1)]
  def cdddar(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("cdddar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("cdddar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("cdddar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("cdddar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    v
  end

  @[Creme::SchemeFn("cddddr", min: 1, max: 1)]
  def cddddr(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("cddddr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("cddddr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("cddddr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("cddddr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    v
  end

  @[Creme::SchemeFn("cdddr", min: 1, max: 1)]
  def cdddr(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("cdddr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("cdddr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("cdddr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    v
  end
end

module Creme
  class Interpreter
    register_library ["creme", "builtin", "cxr"], Creme::R7RS::Cxr
  end
end
