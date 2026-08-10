# ===========================================================================
# hardware module: best-effort local CPU/memory info, for reports (e.g.
# competition/bench.scm's benchmarks/<arch>_<os>.md snapshots) that need to
# say what machine a run happened on -- distinct from (creme introspection)'s
# `runtime` (which identifies the VM/compiler/OS/arch, not the physical box).
# ===========================================================================
#
# hardware-info -> a flat alist: (("cpu-model" . string-or-#f)
# ("cpu-cores" . integer) ("memory-total" . integer-or-#f)). Unlike `runtime`
# (whose os/arch always succeed on any POSIX box creme runs on at all),
# CPU model and memory are gathered best-effort per OS -- #f, never a raised
# error, on any lookup this machine/OS doesn't support. `cpu-cores` is the
# one field with a genuinely portable source (Crystal's own System.cpu_count)
# and is always populated.
#
# Native creme only, deliberately -- like (creme prof-native), there's no
# icecreme counterpart. Its only consumer, competition/bench.scm, always
# runs under native `bin/creme` (see that script's own header comment), so
# there's nothing for an icecreme copy to serve.

module Creme::Builtins::Hardware
  extend self
  include Creme::BuiltinHelpers

  @[Creme::SchemeFn("hardware-info", min: 0, max: 0)]
  def hardware_info(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    os = uname_field("-s")
    model = cpu_model(os)
    memory = memory_total(os)
    Creme.a_to_list([
      Cons.new(SchemeSym.of("cpu-model"), (model ? SchemeStr.new(model) : FALSE).as(SchemeValue)).as(SchemeValue),
      Cons.new(SchemeSym.of("cpu-cores"), SchemeInt.new(System.cpu_count.to_i64)).as(SchemeValue),
      Cons.new(SchemeSym.of("memory-total"), (memory ? SchemeInt.new(memory) : FALSE).as(SchemeValue)).as(SchemeValue),
    ])
  end

  # Same "-s" as (creme introspection)'s own uname_field, but not shared
  # with it directly -- that method is private to Introspection's module,
  # and duplicating one four-line shell-out here is simpler than exporting
  # a cross-module helper for a single call site.
  private def uname_field(flag : String) : String
    io = IO::Memory.new
    status = ::Process.run("uname", [flag], output: io)
    raise SchemeRuntimeError.new("hardware-info: `uname #{flag}` failed") unless status.success?
    io.to_s.chomp
  end

  # `sysctl -n NAME`'s stdout, or nil on any failure (unknown key, sysctl not
  # on PATH, non-BSD/Darwin platform) -- best-effort, unlike uname_field
  # above (which raises): sysctl's exact key set isn't part of any promised
  # contract the way uname -s/-m is.
  private def sysctl_value(name : String) : String?
    io = IO::Memory.new
    status = ::Process.run("sysctl", ["-n", name], output: io)
    return nil unless status.success?
    value = io.to_s.strip
    value.empty? ? nil : value
  end

  private def cpu_model(os : String) : String?
    case os
    when "FreeBSD" then sysctl_value("hw.model")
    when "Darwin"  then sysctl_value("machdep.cpu.brand_string") || sysctl_value("hw.model")
    when "Linux"   then linux_cpu_model
    else                nil
    end
  end

  private def memory_total(os : String) : Int64?
    case os
    when "FreeBSD" then sysctl_value("hw.physmem").try(&.to_i64?)
    when "Darwin"  then sysctl_value("hw.memsize").try(&.to_i64?)
    when "Linux"   then linux_memory_total
    else                nil
    end
  end

  # /proc/cpuinfo's first "model name" line's value, e.g. "AMD Ryzen 9
  # 7900X 12-Core Processor" -- absent on some ARM kernels (which report
  # "Hardware"/"Model" instead), so this can legitimately return nil on
  # Linux too, not just on non-Linux platforms.
  private def linux_cpu_model : String?
    return nil unless File.exists?("/proc/cpuinfo")
    File.each_line("/proc/cpuinfo") do |line|
      if line.starts_with?("model name")
        parts = line.split(':', 2)
        value = parts[1]?.try(&.strip)
        return value if value && !value.empty?
      end
    end
    nil
  rescue
    nil
  end

  # /proc/meminfo's "MemTotal:" line, reported in kB -- converted to bytes
  # to match the sysctl-backed fields above (hw.physmem/hw.memsize are both
  # already byte counts).
  private def linux_memory_total : Int64?
    return nil unless File.exists?("/proc/meminfo")
    File.each_line("/proc/meminfo") do |line|
      if line.starts_with?("MemTotal:")
        digits = line.gsub(/[^0-9]/, "")
        kb = digits.to_i64?
        return kb * 1024 if kb
      end
    end
    nil
  rescue
    nil
  end
end

module Creme
  class Interpreter
    register_library ["creme", "builtin", "hardware"], Creme::Builtins::Hardware
  end
end
