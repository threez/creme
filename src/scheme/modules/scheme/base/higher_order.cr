# ===========================================================================
# (scheme base): higher-order procedures, environments, values, call/cc
# ===========================================================================

module Scheme::Builtins::HigherOrder
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("map", min: 2, max: -1)]
  def map(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    f = args[0]
    lists = args[1..-1].map { |list| Scheme.list_to_a(list) }
    minlen = lists.min_of(&.size)
    acc = [] of SchemeValue
    (0...minlen).each do |i|
      call_args = lists.map { |list| list[i] }
      acc << interp.apply(f, call_args)
    end
    Scheme.a_to_list(acc)
  end

  @[Scheme::SchemeFn("for-each", min: 2, max: -1)]
  def for_each(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    f = args[0]
    lists = args[1..-1].map { |list| Scheme.list_to_a(list) }
    minlen = lists.min_of(&.size)
    (0...minlen).each do |i|
      call_args = lists.map { |list| list[i] }
      interp.apply(f, call_args)
    end
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("apply", min: 2, max: -1)]
  def apply(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    f = args[0]
    middle = args[1...args.size - 1]
    last = args[args.size - 1]
    call_args = middle + Scheme.list_to_a(last)
    interp.apply(f, call_args)
  end

  @[Scheme::SchemeFn("eval", min: 1, max: 2)]
  def eval(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    target_env = args.size == 2 ? environment_specifier_arg(args[1], "eval") : interp.global
    # Eval'd data has no enclosing lexical frame -> analyze with an empty scope.
    BytecodeCompiler.run_program(interp, [args[0]], target_env)
  end

  # (environment list...) — a fresh, otherwise-empty Env populated by
  # importing each list as an import set (the same grammar/mechanism
  # eval_import uses for a program's own top-level import declarations).
  # The resulting environment specifier's bindings are immutable in the
  # sense that R7RS describes (this implementation doesn't separately
  # enforce that; nothing here differs from any other Env in practice).
  @[Scheme::SchemeFn("environment", min: 0, max: -1)]
  def environment(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    target_env = Env.new
    args.each { |import_set| interp.import_into(target_env, import_set) }
    SchemeEnvironment.new(target_env)
  end

  # (null-environment version) — an environment with only the syntactic
  # keywords bound, no procedures. `version` (5, matching R5RS) is
  # accepted but otherwise unused, per R7RS's own description of this
  # procedure existing for R5RS-compatibility purposes.
  @[Scheme::SchemeFn("null-environment", min: 0, max: 1)]
  def null_environment(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    target_env = Env.new
    interp.install_special_forms(target_env)
    SchemeEnvironment.new(target_env)
  end

  # (scheme-report-environment version) — an environment containing the
  # R5RS-report bindings. This implementation doesn't maintain a
  # separate R5RS-vs-R7RS binding set, so, like null-environment, this
  # wraps @base_env (the same bindings (scheme base) itself wraps).
  @[Scheme::SchemeFn("scheme-report-environment", min: 0, max: 1)]
  def scheme_report_environment(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeEnvironment.new(interp.base_env)
  end

  # (interaction-environment) — a specifier for the environment a REPL
  # would evaluate typed-in expressions against, i.e. @global itself.
  @[Scheme::SchemeFn("interaction-environment", min: 0, max: 0)]
  def interaction_environment(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeEnvironment.new(interp.global)
  end

  # (values x) is x itself, not a wrapped single-element SchemeValues —
  # `values` is transparent outside call-with-values, per R7RS.
  @[Scheme::SchemeFn("values", min: 0, max: -1)]
  def values(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    args.size == 1 ? args[0] : SchemeValues.new(args).as(SchemeValue)
  end

  @[Scheme::SchemeFn("call-with-values", min: 2, max: 2)]
  def call_with_values(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    producer, consumer = args[0], args[1]
    result = interp.apply(producer, [] of SchemeValue)
    interp.apply(consumer, values_to_a(result))
  end

  # call/cc: escape continuations only (non-local exit / early return /
  # guard-style unwinding), not full R7RS multi-shot re-entrant
  # continuations — see Interpreter#call_cc's doc comment for the
  # mechanism and its limits.
  @[Scheme::SchemeFn("call/cc", min: 1, max: 1)]
  def call_cc(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    interp.call_cc(args[0])
  end

  @[Scheme::SchemeFn("call-with-current-continuation", min: 1, max: 1)]
  def call_with_current_continuation(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    interp.call_cc(args[0])
  end

  # (dynamic-wind before thunk after): before/after always run in pairs
  # around thunk, even when thunk escapes via a call/cc continuation,
  # an uncaught SchemeError, or (exit ...) — Crystal's `ensure` doesn't
  # discriminate the unwind's cause, so after always fires. Since
  # call/cc here is escape-only (see Interpreter#call_cc's own doc
  # comment), what this does NOT provide is R7RS's full requirement that
  # `before` re-fires when a continuation captured INSIDE this
  # dynamic-wind is later invoked to re-enter it from OUTSIDE, after
  # dynamic-wind itself already returned — that needs true re-entrant
  # continuations. Invoking such a continuation here instead raises the
  # existing "continuation invoked outside its dynamic extent" error (see
  # call_cc/apply's SchemeContinuation arm) rather than behaving
  # incorrectly.
  @[Scheme::SchemeFn("dynamic-wind", min: 3, max: 3)]
  def dynamic_wind(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    before, thunk, after = args[0], args[1], args[2]
    interp.apply(before, [] of SchemeValue)
    begin
      interp.apply(thunk, [] of SchemeValue)
    ensure
      interp.apply(after, [] of SchemeValue)
    end
  end
end

module Scheme
  class Interpreter
    private def install_higher_order(env : Env) : Nil
      register_module(Scheme::Builtins::HigherOrder, env)
    end

    # Escape-only call/cc: mints a tag unique to this invocation, marks it
    # live for the duration of `f`'s call, and hands `f` a SchemeContinuation
    # carrying that tag. Interpreter#apply's SchemeContinuation arm raises
    # ContinuationInvoked(tag, value) when the continuation is applied; this
    # rescue only catches its OWN tag (a nested call/cc's escape must pass
    # through untouched, hence `raise ex unless ex.tag == tag`), and the
    # `ensure` un-marks the tag as live regardless of how this call ends —
    # success, an ordinary error, or a matching continuation invocation —
    # so a stale (already-returned) continuation is never mistaken for a
    # live one: @cc_tag_counter only increases and tags are never reused.
    def call_cc(f : SchemeValue) : SchemeValue
      @cc_tag_counter += 1
      tag = @cc_tag_counter
      @live_continuation_tags << tag
      begin
        apply(f, [SchemeContinuation.new(tag).as(SchemeValue)])
      rescue ex : ContinuationInvoked
        raise ex unless ex.tag == tag
        ex.value
      ensure
        @live_continuation_tags.delete(tag)
      end
    end
  end
end
