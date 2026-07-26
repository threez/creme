# ===========================================================================
# introspection module: interpreter-level operations with no R7RS equivalent
# ===========================================================================
#
# macro?/gensym are the two names (creme extra) deliberately left behind when
# it moved to modules/creme/extra.sld (see that file's header comment) —
# genuine Crystal-level operations with no R7RS equivalent, so they can't be
# expressed in a portable .sld. They live in this module (rather than in a
# (scheme base) section file) so (creme introspection) owns them directly and
# derives its exports from register_module.

module Scheme::Builtins::Introspection
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("macro?", min: 1, max: 1)]
  def macro_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(args[0].is_a?(Macro))
  end

  @[Scheme::SchemeFn("gensym", min: 0, max: 1)]
  def gensym(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    prefix = case a = args[0]?
             when SchemeStr then a.value
             when SchemeSym then a.name
             when Nil       then "g"
             else                raise SchemeRuntimeError.new("gensym: expected a string or symbol prefix")
             end
    interp.gensym(prefix)
  end

  # Generic runtime reflection over any define-record-type instance: every
  # record, regardless of its type, is backed by the same SchemeRecord class
  # (a SchemeRecordType + a positional Array(SchemeValue) — see
  # eval/record.cr), so this needs no per-type dispatch. Exists so a `match`
  # macro can destructure record fields by POSITION instead of needing to
  # synthesize each type's generated accessor name (impossible with
  # unhygienic syntax-rules alone) — see modules/creme/match.sld.
  @[Scheme::SchemeFn("record-fields", min: 1, max: 1)]
  def record_fields(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("record-fields: expected a record instance, got #{v.write_string}") unless v.is_a?(SchemeRecord)
    Scheme.a_to_list(v.fields)
  end

  # Whether STDOUT is attached to an actual terminal (as opposed to a pipe
  # or a redirected file) -- so a script (e.g. (creme spec)'s runner) can
  # decide whether ANSI color codes would help or would just corrupt piped/
  # redirected output with escape sequences. No args: always asks about
  # this process's own STDOUT specifically, not an arbitrary port -- there's
  # no general notion of "the underlying fd" for a Scheme string/output
  # port here, so this deliberately isn't `port-tty?` taking a port arg.
  @[Scheme::SchemeFn("stdout-tty?", min: 0, max: 0)]
  def stdout_tty_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(STDOUT.tty?)
  end
end

module Scheme
  class Interpreter
    register_library ["creme", "introspection"], Scheme::Builtins::Introspection
  end
end
