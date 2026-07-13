# ===========================================================================
# process module: running external commands, program arguments
# ===========================================================================

module Scheme
  class Interpreter
    private def install_process(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(SchemeValue) -> SchemeValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      reg.call("process-run", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        cmd = args[0]
        raise SchemeRuntimeError.new("process-run: expected string command, got #{cmd.write_string}") unless cmd.is_a?(SchemeStr)
        cmd_args = Scheme.list_to_a(args[1]).map do |elem|
          raise SchemeRuntimeError.new("process-run: expected list of strings, got #{elem.write_string}") unless elem.is_a?(SchemeStr)
          elem.value
        end

        stdout_io = IO::Memory.new
        stderr_io = IO::Memory.new
        begin
          status = Process.run(cmd.value, cmd_args, output: stdout_io, error: stderr_io)
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
      end)

      # R7RS-exact name/contract: (command-line) -> list of strings, whose
      # first element is the program name. This module's Crystal-native ARGV
      # doesn't include the program name, so it's prepended here.
      reg.call("command-line", 0, 0, ->(_args : Array(SchemeValue)) : SchemeValue do
        Scheme.a_to_list(([PROGRAM_NAME] + ARGV).map { |arg| SchemeStr.new(arg).as(SchemeValue) })
      end)
    end
  end
end
