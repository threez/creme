# ===========================================================================
# (scheme base): parameters, error conditions, misc
# ===========================================================================
#
# force/make-promise/promise? live in (scheme lazy); exit in (scheme
# process-context); gensym in (creme introspection) — each defined in that
# library's own module file. `interp.gensym` (below) stays here since the
# analyzer's own macro expansion uses it directly.

module Creme::R7RS::Misc
  extend self
  include Creme::BuiltinHelpers

  # The initial value is converted too (R7RS): a parameter's value is
  # always the converter's output, never the raw input, so reads never
  # need to re-apply it.
  @[Creme::SchemeFn("make-parameter", min: 1, max: 2)]
  def make_parameter(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    converter = args[1]?
    initial = converter ? interp.apply(converter, [args[0]]) : args[0]
    SchemeParameter.new(initial, converter).as(SchemeValue)
  end

  @[Creme::SchemeFn("error", min: 1, max: -1)]
  def error(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    buf = String::Builder.new
    msg = args[0]
    if msg.is_a?(SchemeStr)
      buf << msg.value
    else
      buf << msg.write_string
    end
    (1...args.size).each do |i|
      buf << ' '
      buf << args[i].write_string
    end
    irritants = args[1..]
    err = SchemeUserError.new(buf.to_s)
    err.payload = SchemeRecord.new(CONDITION_TYPE, [msg, Creme.a_to_list(irritants)] of SchemeValue)
    raise err
  end

  # syntax-error is meant for use inside a syntax-rules template (a
  # macro-expansion-time error), but since this interpreter has no
  # separate expansion phase, it behaves the same as `error` when
  # reached during ordinary evaluation.
  @[Creme::SchemeFn("syntax-error", min: 1, max: -1)]
  def syntax_error(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    interp.apply(env.get("error"), args)
  end

  @[Creme::SchemeFn("features", min: 0, max: 0)]
  def features(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    Creme.a_to_list(interp.features.map { |feature| SchemeSym.of(feature).as(SchemeValue) })
  end

  # simplest-rational-in-interval (Stern-Brocot style): the exact
  # rational (or, if either input is inexact, the corresponding
  # inexact value) of least denominator within `epsilon` of `x`.
  @[Creme::SchemeFn("rationalize", min: 2, max: 2)]
  def rationalize(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    x, epsilon = args[0], args[1]
    inexact_result = Creme.inexact?(x) || Creme.inexact?(epsilon)
    xf = Creme.as_f64(x, "rationalize")
    ef = Creme.as_f64(epsilon, "rationalize").abs
    num, den = simplest_rational_between(xf - ef, xf + ef)
    inexact_result ? SchemeFloat.new(num.to_f64 / den.to_f64).as(SchemeValue) : SchemeRational.make(num, den)
  end

  @[Creme::SchemeFn("error-object?", min: 1, max: 1)]
  def error_object_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    SchemeBool.of(v.is_a?(SchemeRecord) && v.type.same?(CONDITION_TYPE))
  end

  @[Creme::SchemeFn("error-object-message", min: 1, max: 1)]
  def error_object_message(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    condition_field(args[0], 0, "error-object-message")
  end

  @[Creme::SchemeFn("error-object-irritants", min: 1, max: 1)]
  def error_object_irritants(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    condition_field(args[0], 1, "error-object-irritants")
  end

  # simplest-rational-in-interval (Stern-Brocot style): the simplest
  # (least-denominator) rational within [lo, hi]. Assumes lo <= hi; if 0
  # is in range, 0/1 is trivially simplest. Used by `rationalize`.
  private def simplest_rational_between(lo : Float64, hi : Float64) : {Int64, Int64}
    return {0_i64, 1_i64} if lo <= 0 && hi >= 0
    if hi < 0
      num, den = simplest_rational_between(-hi, -lo)
      return {-num, den}
    end

    lo_n, lo_d = 0_i64, 1_i64
    hi_n, hi_d = 1_i64, 0_i64
    loop do
      mid_n = lo_n + hi_n
      mid_d = lo_d + hi_d
      mid = mid_n.to_f64 / mid_d.to_f64
      if mid < lo
        lo_n, lo_d = mid_n, mid_d
      elsif mid > hi
        hi_n, hi_d = mid_n, mid_d
      else
        return {mid_n, mid_d}
      end
    end
  end

  private def condition_field(v : SchemeValue, idx : Int32, who : String) : SchemeValue
    raise SchemeRuntimeError.new("#{who}: expected an error object, got #{v.write_string}") unless v.is_a?(SchemeRecord) && v.type.same?(CONDITION_TYPE)
    v.fields[idx]
  end
end

module Creme
  class Interpreter
    private def install_misc(env : Env) : Array(String)
      register_module(Creme::R7RS::Misc, env)
    end

    def gensym(prefix : String) : SchemeSym
      @gensym_counter += 1
      SchemeSym.of("#{prefix}__#{@gensym_counter}")
    end
  end
end
