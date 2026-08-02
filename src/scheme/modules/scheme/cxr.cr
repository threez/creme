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

module Scheme::Builtins::Cxr
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("caaaar", min: 1, max: 1)]
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

  @[Scheme::SchemeFn("caaadr", min: 1, max: 1)]
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

  @[Scheme::SchemeFn("caaar", min: 1, max: 1)]
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

  @[Scheme::SchemeFn("caadar", min: 1, max: 1)]
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

  @[Scheme::SchemeFn("caaddr", min: 1, max: 1)]
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

  @[Scheme::SchemeFn("caadr", min: 1, max: 1)]
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

  @[Scheme::SchemeFn("cadaar", min: 1, max: 1)]
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

  @[Scheme::SchemeFn("cadadr", min: 1, max: 1)]
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

  @[Scheme::SchemeFn("cadar", min: 1, max: 1)]
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

  @[Scheme::SchemeFn("caddar", min: 1, max: 1)]
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

  @[Scheme::SchemeFn("cadddr", min: 1, max: 1)]
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

  @[Scheme::SchemeFn("caddr", min: 1, max: 1)]
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

  @[Scheme::SchemeFn("cdaaar", min: 1, max: 1)]
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

  @[Scheme::SchemeFn("cdaadr", min: 1, max: 1)]
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

  @[Scheme::SchemeFn("cdaar", min: 1, max: 1)]
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

  @[Scheme::SchemeFn("cdadar", min: 1, max: 1)]
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

  @[Scheme::SchemeFn("cdaddr", min: 1, max: 1)]
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

  @[Scheme::SchemeFn("cdadr", min: 1, max: 1)]
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

  @[Scheme::SchemeFn("cddaar", min: 1, max: 1)]
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

  @[Scheme::SchemeFn("cddadr", min: 1, max: 1)]
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

  @[Scheme::SchemeFn("cddar", min: 1, max: 1)]
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

  @[Scheme::SchemeFn("cdddar", min: 1, max: 1)]
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

  @[Scheme::SchemeFn("cddddr", min: 1, max: 1)]
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

  @[Scheme::SchemeFn("cdddr", min: 1, max: 1)]
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

module Scheme
  class Interpreter
    register_library ["creme", "builtin", "cxr"], Scheme::Builtins::Cxr
  end
end
