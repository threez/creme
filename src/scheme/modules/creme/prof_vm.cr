# ===========================================================================
# prof-vm module: cooperative Scheme-level sampling profiler, exposed to
# Scheme
# ===========================================================================
#
# `profile-scheme`/`profile-scheme-top`/... drive a cooperative sampler
# (Interpreter#start_scheme_sampling/#stop_scheme_sampling,
# src/scheme/eval/interpreter.cr) that periodically inspects the instruction
# currently at the top of the VM's fetch-decode-dispatch loop (VM#execute,
# src/scheme/eval/vm.cr) — not from a signal handler. Reading interpreter
# state from prof.cr's SIGPROF handler (see prof_native.cr, the other half
# of this pair) would be unsafe (mid-mutation GC-managed state the
# interpreter thread could be touching when a signal lands, exactly the
# class of hazard a signal handler must avoid); running the check
# synchronously on the interpreter's own thread (always single-fiber per
# instance, so no locking needed) sidesteps that entirely, at the cost of
# being counted in trampoline steps rather than wall-clock time. Samples are
# attributed to the current INSTRUCTION, not the innermost enclosing named
# call — an enclosing-call-only attribution was tried first and always
# collapsed to one entry (e.g. `(fib 27)` showed 100% "fib", no `if`/`-`/`+`
# visibility) since a builtin call like `cons` pushes/pops its call-stack
# frame entirely within one trampoline iteration, so a sample checkpoint
# could never land "inside" it. This is the sampler that shows which
# Scheme-level operation — a call site reconstructed from its own source
# ("(fib (- n 1))"), an inlined primitive's call form ("(+ (fib ...) (fib
# ...))"), or a control construct ("if", "let*") — is hot, each with the
# file/line it came from (see Chunk#sample_tags/Interpreter.op_label for the
# exact instruction -> label mapping).
#
# Unlike prof_native.cr, this file has no native/backtrace(3) dependency, so
# it's available on every platform including musl (Alpine) — see
# src/scheme.cr's require for the two files' differing guards, and
# modules/creme/prof.sld's own header comment for how the two are combined
# back into `(creme prof)`.

module Scheme
  # Result of profile-scheme: sample counts by Interpreter::SampleKey (a
  # source-resembling label plus the file/line it came from — see
  # Interpreter#sample_label), collected by Interpreter's cooperative sampler
  # (see interpreter.cr). Plain data, no Crystal FFI involved — kept in this
  # file since it only exists for (creme prof-vm)'s own use.
  struct SchemeProfileReport
    getter counts : Hash(Interpreter::SampleKey, Int32)
    getter total : Int32

    def initialize(@counts : Hash(Interpreter::SampleKey, Int32), @total : Int32)
    end
  end
end

module Scheme::Builtins::ProfVM
  extend self
  include Scheme::BuiltinHelpers

  # (profile-scheme thunk [step-interval]) -> a profile-scheme-report.
  # Calls `thunk` (a procedure of no arguments) under the cooperative
  # Scheme-level sampler and returns the collected report; the sampler is
  # always stopped even if `thunk` raises. `step-interval` (default 1000)
  # is how many VM instruction dispatches elapse between samples — smaller
  # values sample more finely but add more overhead.
  @[Scheme::SchemeFn("profile-scheme", min: 1, max: 2)]
  def profile_scheme(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    thunk = args[0]
    interval_steps = args.size == 2 ? int_arg(args[1], "profile-scheme").to_i32 : 1000
    interp.start_scheme_sampling(interval_steps)
    counts = {} of Interpreter::SampleKey => Int32
    begin
      interp.apply(thunk, [] of SchemeValue)
    ensure
      counts = interp.stop_scheme_sampling
    end
    report = SchemeProfileReport.new(counts, counts.values.sum)
    SchemeBox.new("scheme-profile-report", report, "#<scheme-profile-report:#{report.total} samples>").as(SchemeValue)
  end

  @[Scheme::SchemeFn("profile-scheme-report?", min: 1, max: 1)]
  def profile_scheme_report_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(args[0].is_a?(SchemeBox) && args[0].as(SchemeBox).tag == "scheme-profile-report")
  end

  @[Scheme::SchemeFn("profile-scheme-total-samples", min: 1, max: 1)]
  def profile_scheme_total_samples(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeInt.new(prof_scheme_report_arg(args[0], "profile-scheme-total-samples").total.to_i64)
  end

  # (profile-scheme-top report n) -> a list of up to n alists, one per
  # hottest sample key, shaped (("name" . str) ("instruction" . str)
  # ("count" . int) ("percent" . flo) ("file" . str-or-#f)
  # ("line" . int-or-#f)) — alist convention for
  # object-shaped data. `name` resembles the actual source at that call
  # site (e.g. "(fib (- n 1))"), not a generic frame name; `instruction`
  # is the KIND of thing it is, in the language's own syntax (e.g. "if",
  # "let*", "call", "+") rather than a Crystal class name.
  @[Scheme::SchemeFn("profile-scheme-top", min: 2, max: 2)]
  def profile_scheme_top(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    report = prof_scheme_report_arg(args[0], "profile-scheme-top")
    n = int_arg(args[1], "profile-scheme-top").to_i32
    total = report.total
    entries = report.counts.to_a.sort_by { |(_, count)| -count }.first(n).map do |(key, count)|
      name, instruction, file, line = key
      percent = total > 0 ? (count * 100.0 / total) : 0.0
      Scheme.a_to_list([
        Cons.new(SchemeStr.new("name"), SchemeStr.new(name).as(SchemeValue)).as(SchemeValue),
        Cons.new(SchemeStr.new("instruction"), SchemeStr.new(instruction).as(SchemeValue)).as(SchemeValue),
        Cons.new(SchemeStr.new("count"), SchemeInt.new(count.to_i64).as(SchemeValue)).as(SchemeValue),
        Cons.new(SchemeStr.new("percent"), SchemeFloat.new(percent).as(SchemeValue)).as(SchemeValue),
        Cons.new(SchemeStr.new("file"), (file ? SchemeStr.new(file) : FALSE).as(SchemeValue)).as(SchemeValue),
        Cons.new(SchemeStr.new("line"), (line ? SchemeInt.new(line.to_i64) : FALSE).as(SchemeValue)).as(SchemeValue),
      ] of SchemeValue).as(SchemeValue)
    end
    Scheme.a_to_list(entries)
  end

  private def prof_scheme_report_arg(v : SchemeValue, who : String) : SchemeProfileReport
    raise SchemeRuntimeError.new("#{who}: expected a scheme profile report, got #{v.write_string}") unless v.is_a?(SchemeBox) && v.tag == "scheme-profile-report"
    v.get(SchemeProfileReport)
  end
end

module Scheme
  class Interpreter
    register_library ["creme", "prof-vm"], Scheme::Builtins::ProfVM
  end
end
