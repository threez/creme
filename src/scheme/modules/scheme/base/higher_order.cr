# ===========================================================================
# (scheme base): higher-order procedures, values, call/cc
#
# eval/environment live in (scheme eval), null-environment/
# scheme-report-environment in (scheme r5rs), and interaction-environment
# in (scheme repl) — each defined in that library's own module file.
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
    private def install_higher_order(env : Env) : Array(String)
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
