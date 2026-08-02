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

module Creme::Builtins::Introspection
  extend self
  include Creme::BuiltinHelpers

  @[Creme::SchemeFn("macro?", min: 1, max: 1)]
  def macro_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(args[0].is_a?(Macro))
  end

  @[Creme::SchemeFn("gensym", min: 0, max: 1)]
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
  @[Creme::SchemeFn("record-fields", min: 1, max: 1)]
  def record_fields(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("record-fields: expected a record instance, got #{v.write_string}") unless v.is_a?(SchemeRecord)
    Creme.a_to_list(v.fields)
  end

  # The runtime this script is currently executing under -- an alist:
  #   ((vm . "crystal"|"icecreme") (compiler . "native"|"self-hosted")
  #    (version . "0.1.0") (os . <uname -s>) (arch . <uname -m>))
  # `vm` is always "crystal" here (icecreme's own copy, icecreme/builtins.c's
  # bi_runtime, always answers "icecreme" instead -- there's no other engine
  # this Crystal-side implementation could possibly be running under).
  # `compiler` distinguishes native Crystal's own tree-walking evaluator
  # from `creme --self-hosted` (both run inside this SAME Interpreter/
  # process) via a marker only run_self_hosted (src/main.cr) defines in
  # interp.global right before running the user's script -- see that
  # method's own comment. `version` is a hardcoded literal (0.1.0) --
  # this project has no other canonical version yet; keep this in sync
  # BY HAND with icecreme/builtins.c's bi_runtime's own copy of the same
  # literal. `os`/`arch` shell out to the real `uname` binary rather than
  # add a LibC binding, so they read exactly what running `uname -s`/
  # `uname -m` yourself would show.
  @[Creme::SchemeFn("runtime", min: 0, max: 0)]
  def runtime(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    compiler = interp.global.get?("__creme_self_hosted__") ? "self-hosted" : "native"
    os = uname_field("-s")
    arch = uname_field("-m")
    Creme.a_to_list([
      Cons.new(SchemeSym.of("vm"), SchemeStr.new("crystal")).as(SchemeValue),
      Cons.new(SchemeSym.of("compiler"), SchemeStr.new(compiler)).as(SchemeValue),
      Cons.new(SchemeSym.of("version"), SchemeStr.new("0.1.0")).as(SchemeValue), # keep in sync with icecreme/builtins.c's bi_runtime
      Cons.new(SchemeSym.of("os"), SchemeStr.new(os)).as(SchemeValue),
      Cons.new(SchemeSym.of("arch"), SchemeStr.new(arch)).as(SchemeValue),
    ])
  end

  # Every name currently bound in the top-level global environment -- the
  # same Env `(interaction-environment)` wraps (see modules/scheme/repl.cr)
  # and the REPL evaluates against -- as a list of strings. Backs REPL tab
  # completion: reflects the LIVE binding set (re-reads interp.global.
  # local_names on every call), not a snapshot taken once at import time, so
  # a `define` since the last call already shows up.
  @[Creme::SchemeFn("bound-names", min: 0, max: 0)]
  def bound_names(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    Creme.a_to_list(interp.global.local_names.map { |name| SchemeStr.new(name).as(SchemeValue) })
  end

  private def uname_field(flag : String) : String
    io = IO::Memory.new
    status = ::Process.run("uname", [flag], output: io)
    raise SchemeRuntimeError.new("runtime: `uname #{flag}` failed") unless status.success?
    io.to_s.chomp
  end

  # An already-registered library's own export alist -- a list of (external
  # . internal) symbol pairs, or #f if that library isn't registered/
  # imported yet -- taking a quoted library name the same shape define-
  # library/import use, e.g. '(creme regex). Exists so modules/creme/
  # compiler/compiler.sld's own library-export-alist (which normally reads
  # a library's exports straight out of its .sld source file) has a
  # fallback for a NATIVE (Crystal-builtin) library, which has no .sld file
  # to read but is already tracked internally regardless (Interpreter#
  # library_exports, backed by each SchemeLibrary's own #exports).
  @[Creme::SchemeFn("library-exports", min: 1, max: 1)]
  def library_exports(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    parts = Creme.list_to_a(args[0]).map do |part|
      raise SchemeRuntimeError.new("library-exports: expected a list of symbols") unless part.is_a?(SchemeSym)
      part.name
    end
    exports = interp.library_exports(parts)
    return FALSE.as(SchemeValue) unless exports
    Creme.a_to_list(exports.map { |external, internal| Cons.new(SchemeSym.new(external), SchemeSym.new(internal)).as(SchemeValue) })
  end
end

module Creme
  class Interpreter
    register_library ["creme", "builtin", "introspection"], Creme::Builtins::Introspection
  end
end
