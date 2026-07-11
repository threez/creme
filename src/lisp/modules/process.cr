# ===========================================================================
# process module: running external commands, program arguments
# ===========================================================================

module LISP
  class Interpreter
    private def install_process(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(LispValue) -> LispValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      reg.call("run", 2, 2, ->(args : Array(LispValue)) : LispValue do
        cmd = args[0]
        raise LispRuntimeError.new("process:run: expected string command, got #{cmd.write_string}") unless cmd.is_a?(LispStr)
        cmd_args = LISP.list_to_a(args[1]).map do |elem|
          raise LispRuntimeError.new("process:run: expected list of strings, got #{elem.write_string}") unless elem.is_a?(LispStr)
          elem.value
        end

        stdout_io = IO::Memory.new
        stderr_io = IO::Memory.new
        begin
          status = Process.run(cmd.value, cmd_args, output: stdout_io, error: stderr_io)
        rescue ex : Exception
          raise LispRuntimeError.new("process:run: #{ex.message}")
        end

        # returns (stdout stderr status success) — use car/cadr/caddr/cadddr to destructure
        LISP.a_to_list([
          LispStr.new(stdout_io.to_s).as(LispValue),
          LispStr.new(stderr_io.to_s).as(LispValue),
          LispInt.new(status.exit_code.to_i64).as(LispValue),
          LispBool.of(status.success?).as(LispValue),
        ])
      end)

      reg.call("args", 0, 0, ->(_args : Array(LispValue)) : LispValue do
        LISP.a_to_list(ARGV.map { |arg| LispStr.new(arg).as(LispValue) })
      end)
    end
  end
end
