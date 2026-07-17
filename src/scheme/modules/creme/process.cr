# ===========================================================================
# process module: running external commands, program arguments
# ===========================================================================
#
# ProcessLibrary holds command-line — the one procedure R7RS's
# (scheme process-context) shares with this module — so (scheme
# process-context) (modules/scheme/process_context.cr) registers it directly
# and derives its exports. ProcessExtra holds the creme-only process-run;
# (creme process) registers BOTH.

module Scheme::Builtins::ProcessLibrary
  extend self
  include Scheme::BuiltinHelpers

  # R7RS-exact name/contract: (command-line) -> list of strings, whose
  # first element is the program name. This module's Crystal-native ARGV
  # doesn't include the program name, so it's prepended here.
  @[Scheme::SchemeFn("command-line", min: 0, max: 0)]
  def command_line(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    Scheme.a_to_list(([PROGRAM_NAME] + ARGV).map { |arg| SchemeStr.new(arg).as(SchemeValue) })
  end
end

# creme-only process control, beyond R7RS's (scheme process-context) contract.
module Scheme::Builtins::ProcessExtra
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("process-run", min: 2, max: 2)]
  def process_run(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    cmd = args[0]
    raise SchemeRuntimeError.new("process-run: expected string command, got #{cmd.write_string}") unless cmd.is_a?(SchemeStr)
    cmd_args = Scheme.list_to_a(args[1]).map do |elem|
      raise SchemeRuntimeError.new("process-run: expected list of strings, got #{elem.write_string}") unless elem.is_a?(SchemeStr)
      elem.value
    end

    stdout_io = IO::Memory.new
    stderr_io = IO::Memory.new
    begin
      status = ::Process.run(cmd.value, cmd_args, output: stdout_io, error: stderr_io)
    rescue ex : Exception
      raise SchemeRuntimeError.new("process-run: #{ex.message}")
    end

    # returns (stdout stderr status success) — use car/cadr/caddr/cadddr to destructure
    Scheme.a_to_list([
      SchemeStr.new(stdout_io.to_s).as(SchemeValue),
      SchemeStr.new(stderr_io.to_s).as(SchemeValue),
      SchemeInt.new(status.exit_code.to_i64).as(SchemeValue),
      SchemeBool.of(status.success?).as(SchemeValue),
    ])
  end
end

module Scheme
  class Interpreter
    register_library ["creme", "process"] do |env|
      register_module(Scheme::Builtins::ProcessLibrary, env) +
        register_module(Scheme::Builtins::ProcessExtra, env)
    end
  end
end
