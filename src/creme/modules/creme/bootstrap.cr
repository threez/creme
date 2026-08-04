# ===========================================================================
# (creme bootstrap): infrastructure for the self-hosting compiler bootstrap.
# ===========================================================================
#
# `load-chunk-bytes` is the missing piece a Scheme-written bytecode compiler
# needs to actually run something it compiled: it turns a bytevector holding
# the "ICE" format (ChunkSerializer/ChunkDeserializer, compile/chunk_*.cr)
# into a real Chunk and runs it as a top-level program in the CALLING env —
# same semantics as BytecodeCompiler.run_program running one already-
# analyzed form, just skipping analyze/compile entirely since the bytes
# already ARE compiled bytecode. This is deliberately the Crystal-VM-hosted
# half of the bootstrap plan: it lets a self-hosted compiler be verified by
# diffing its output against Crystal's own native pipeline before any of
# this is pointed at icecreme (which has its own, much narrower, opcode/value
# support — see icecreme/README.md).
module Creme::Builtins::BootstrapLibrary
  extend self
  include Creme::BuiltinHelpers

  # Runs the loaded program against `interp.global` — the same env
  # BytecodeCompiler.run_program falls back to for a top-level program with
  # no env of its own — rather than this builtin's own defining env: a
  # library's registered builtins each close over the (creme bootstrap)
  # library's OWN (near-empty) env (see builtin_registration.cr), which is
  # not where `+`/`*`/etc. — or anything else a compiled program's
  # GetGlobal/CallGlobal/DefGlobal need to resolve — actually live.
  @[Creme::SchemeFn("load-chunk-bytes", min: 1, max: 1)]
  def load_chunk_bytes(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    blob = args[0].as?(SchemeBlob) || raise SchemeRuntimeError.new("load-chunk-bytes: expected a bytevector, got #{args[0].class}")
    chunk = begin
      ChunkDeserializer.deserialize(blob.value, interp.global)
    rescue ex : ChunkDeserializer::FormatError
      raise SchemeRuntimeError.new("load-chunk-bytes: #{ex.message}")
    end
    VM.new(interp, interp.global).run(chunk)
  end

  # A Scheme-callable route to `Interpreter#import_into`, for a compiled
  # program's own top-level `import` forms (see modules/creme/compiler/
  # compiler.sld's compile-import!, which desugars `(import spec ...)`
  # into `(import! '(spec ...))`) — takes a plain list of import-sets
  # (the `import` form's own cdr; import_into never looks at a leading
  # `import` tag, so there's no need to fabricate one) and copies each
  # one's bindings into `interp.global`, same target env load-chunk-bytes
  # already runs every compiled program against. `Interpreter.current`
  # (not the closed-over `interp`) matches the established pattern in
  # eval.cr/load.cr for resolving the actually-running interpreter,
  # since actor Fibers each have their own.
  @[Creme::SchemeFn("import!", min: 1, max: 1)]
  def import_bang(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    active = Interpreter.current || interp
    Creme.list_to_a(args[0]).each { |spec| active.import_into(active.global, spec) }
    NIL
  end

  # expand-if-macro: (expand-if-macro form) -> (cons #t expansion) if
  # `form`'s head currently resolves, in the target global env, to a
  # Macro/SchemeSyntaxRules value; otherwise plain #f. Mirrors
  # analyze_cons's own env.get?(head.name) fallback check
  # (analyzer.cr:131) -- the piece a self-hosted compiler has no other
  # way to replicate, since detecting "is this bound to a macro" and
  # expanding it both need Crystal-internal state (Macro/
  # SchemeSyntaxRules aren't just data the reader/writer can see). The
  # #t/#f-vs-pair? distinction disambiguates "found, expansion happens
  # to be literally #f" from "not a macro at all" without a separate
  # sentinel.
  @[Creme::SchemeFn("expand-if-macro", min: 1, max: 1)]
  def expand_if_macro(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    form = args[0].as?(Cons) || raise SchemeRuntimeError.new("expand-if-macro: expected a pair, got #{args[0].write_string}")
    head = form.car
    return FALSE.as(SchemeValue) unless head.is_a?(SchemeSym)
    active = Interpreter.current || interp
    binding = active.global.get?(head.name)
    return FALSE.as(SchemeValue) unless binding.is_a?(Macro) || binding.is_a?(SchemeSyntaxRules)
    expanded = active.expand_macro_binding(binding, form)
    expanded ? Cons.new(TRUE, expanded).as(SchemeValue) : FALSE.as(SchemeValue)
  end
end

module Creme
  class Interpreter
    register_library ["creme", "builtin", "bootstrap"], Creme::Builtins::BootstrapLibrary

    # Dispatches to expand_defmacro/expand_syntax_rules -- the same
    # expansion logic analyze_cons already uses for a macro use it finds
    # locally -- just reachable now from a builtin instead of only from
    # analysis. Both callees are private methods on this same class
    # (interpreter.cr, syntax_rules.cr respectively), callable here
    # without an explicit receiver regardless of which file defines them.
    def expand_macro_binding(binding : SchemeValue, form : Cons) : SchemeValue?
      case binding
      when Macro             then expand_defmacro(binding, form)
      when SchemeSyntaxRules then expand_syntax_rules(binding, form)
      else                        nil
      end
    end
  end
end
