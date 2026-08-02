# ===========================================================================
# prof-native module: native CPU sampling profiler (threez/prof.cr), exposed
# to Scheme
# ===========================================================================
#
# `profile`/`profile-top`/... wrap prof.cr's SIGPROF-based sampler, which
# unwinds the raw native C stack on a signal. Since every Scheme call funnels
# through the same handful of Crystal methods (VM#execute, Interpreter#apply,
# ...), its frame names are Crystal internals, not Scheme function
# names — useful for finding hot spots in the *interpreter itself*, not in
# the guest program. See prof_vm.cr for the other half of this pair — a
# cooperative sampler that instead shows which SCHEME-level operation is hot.
#
# Not present on musl (Alpine) — prof.cr has no backtrace(3) there and fails
# to compile; this whole file is skipped via a require guard in
# src/creme.cr, so creme still builds on Alpine, just without
# `(creme prof-native)` (and, transitively, `(creme prof)` — see
# modules/creme/prof.sld's own header comment). prof_vm.cr has no such
# restriction and stays available everywhere.
#
# The report is opaque foreign state, boxed the same way (creme regex)/
# (creme sql) box a Regex/DB connection — via SchemeBox
# (src/creme/value/box.cr) — tagged "prof-report" rather than a dedicated
# SchemeValue subclass.
#
# `profile-top`'s frame names are returned RAW (Prof::Frame#name — Crystal's
# mangled symbol, which can be very long for a method generic over
# SchemeValue's big union) — this module doesn't try to prettify them;
# that's presentation logic, left to the calling Scheme script (see
# bench/prof.scm's own trimming).

require "prof"

module Creme::Builtins::ProfNative
  extend self
  include Creme::BuiltinHelpers

  # (profile thunk [interval-ms]) -> a profile-report. Calls `thunk` (a
  # procedure of no arguments) under the sampling profiler and returns
  # the collected report; the profiler is stopped/cleaned up even if
  # `thunk` raises (prof.cr's own guarantee) — any Scheme-level error
  # `thunk` raises propagates through this call unchanged, same as any
  # other builtin that invokes a callback (map, for-each, ...).
  @[Creme::SchemeFn("profile", min: 1, max: 2)]
  def profile(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    thunk = args[0]
    interval_ms = args.size == 2 ? prof_interval_arg(args[1]) : 1.0
    report =
      begin
        ::Prof.profile(interval: interval_ms.milliseconds) { interp.apply(thunk, [] of SchemeValue) }
      rescue ex : SchemeError | SchemeExit | ContinuationInvoked
        # A Scheme-level error/exit/call-cc-escape from `thunk` itself — not
        # a prof.cr-internal failure. Let it propagate exactly as it would
        # from any other builtin that invokes a callback.
        raise ex
      rescue ex : Exception
        raise SchemeRuntimeError.new("profile: #{ex.message}")
      end
    SchemeBox.new("prof-report", report, "#<prof-report:#{report.total_samples} samples>").as(SchemeValue)
  end

  @[Creme::SchemeFn("profile-report?", min: 1, max: 1)]
  def profile_report_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(args[0].is_a?(SchemeBox) && args[0].as(SchemeBox).tag == "prof-report")
  end

  @[Creme::SchemeFn("profile-total-samples", min: 1, max: 1)]
  def profile_total_samples(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeInt.new(prof_report_arg(args[0], "profile-total-samples").total_samples.to_i64)
  end

  # (profile-top report n) -> a list of up to n alists, one per hottest
  # frame, each shaped (("name" . str) ("count" . int) ("percent" . flo)
  # ("file" . str-or-#f) ("line" . int-or-#f)) — alist convention for
  # object-shaped data (matches (creme sql)'s row shape).
  @[Creme::SchemeFn("profile-top", min: 2, max: 2)]
  def profile_top(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    report = prof_report_arg(args[0], "profile-top")
    n = int_arg(args[1], "profile-top").to_i32
    total = report.total_samples
    entries = report.top(n).map do |(frame, count)|
      percent = total > 0 ? (count * 100.0 / total) : 0.0
      file = frame.file
      line = frame.line
      Creme.a_to_list([
        Cons.new(SchemeStr.new("name"), SchemeStr.new(frame.name).as(SchemeValue)).as(SchemeValue),
        Cons.new(SchemeStr.new("count"), SchemeInt.new(count.to_i64).as(SchemeValue)).as(SchemeValue),
        Cons.new(SchemeStr.new("percent"), SchemeFloat.new(percent).as(SchemeValue)).as(SchemeValue),
        Cons.new(SchemeStr.new("file"), (file ? SchemeStr.new(file) : FALSE).as(SchemeValue)).as(SchemeValue),
        Cons.new(SchemeStr.new("line"), (line ? SchemeInt.new(line.to_i64) : FALSE).as(SchemeValue)).as(SchemeValue),
      ] of SchemeValue).as(SchemeValue)
    end
    Creme.a_to_list(entries)
  end

  @[Creme::SchemeFn("profile-write-folded", min: 2, max: 2)]
  def profile_write_folded(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    report = prof_report_arg(args[0], "profile-write-folded")
    path = string_arg(args[1], "profile-write-folded")
    begin
      report.to_folded(path)
    rescue ex : Exception
      raise SchemeRuntimeError.new("profile-write-folded: #{ex.message}")
    end
    NIL.as(SchemeValue)
  end

  @[Creme::SchemeFn("profile-write-speedscope", min: 2, max: 3)]
  def profile_write_speedscope(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    report = prof_report_arg(args[0], "profile-write-speedscope")
    path = string_arg(args[1], "profile-write-speedscope")
    name = args.size == 3 ? string_arg(args[2], "profile-write-speedscope") : "CPU Profile"
    begin
      report.to_speedscope(path, name)
    rescue ex : Exception
      raise SchemeRuntimeError.new("profile-write-speedscope: #{ex.message}")
    end
    NIL.as(SchemeValue)
  end

  private def prof_report_arg(v : SchemeValue, who : String) : ::Prof::Report
    raise SchemeRuntimeError.new("#{who}: expected a profile report, got #{v.write_string}") unless v.is_a?(SchemeBox) && v.tag == "prof-report"
    v.get(::Prof::Report)
  end

  private def prof_interval_arg(v : SchemeValue) : Float64
    case v
    when SchemeInt   then v.value.to_f64
    when SchemeFloat then v.value
    else                  raise SchemeRuntimeError.new("profile: expected a number for interval-ms, got #{v.write_string}")
    end
  end
end

module Creme
  class Interpreter
    register_library ["creme", "builtin", "prof-native"], Creme::Builtins::ProfNative
  end
end
