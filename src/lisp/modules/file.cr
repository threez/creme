# ===========================================================================
# file module: whole-file read/write helpers
# ===========================================================================

module LISP
  class Interpreter
    private def install_file(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(LispValue) -> LispValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      reg.call("read", 1, 1, ->(args : Array(LispValue)) : LispValue do
        path = file_str_arg(args[0], "file:read")
        raise LispRuntimeError.new("file:read: file not found: #{path}") unless File.exists?(path)
        begin
          LispStr.new(File.read(path))
        rescue ex : Exception
          raise LispRuntimeError.new("file:read: #{ex.message}")
        end
      end)

      reg.call("write", 2, 2, ->(args : Array(LispValue)) : LispValue do
        path = file_str_arg(args[0], "file:write")
        content = file_str_arg(args[1], "file:write")
        begin
          File.write(path, content)
        rescue ex : Exception
          raise LispRuntimeError.new("file:write: #{ex.message}")
        end
        NIL.as(LispValue)
      end)

      reg.call("append", 2, 2, ->(args : Array(LispValue)) : LispValue do
        path = file_str_arg(args[0], "file:append")
        content = file_str_arg(args[1], "file:append")
        begin
          File.open(path, "a", &.print(content))
        rescue ex : Exception
          raise LispRuntimeError.new("file:append: #{ex.message}")
        end
        NIL.as(LispValue)
      end)

      reg.call("exists?", 1, 1, ->(args : Array(LispValue)) : LispValue do
        LispBool.of(File.exists?(file_str_arg(args[0], "file:exists?")))
      end)

      reg.call("delete", 1, 1, ->(args : Array(LispValue)) : LispValue do
        path = file_str_arg(args[0], "file:delete")
        raise LispRuntimeError.new("file:delete: file not found: #{path}") unless File.exists?(path)
        begin
          File.delete(path)
        rescue ex : Exception
          raise LispRuntimeError.new("file:delete: #{ex.message}")
        end
        NIL.as(LispValue)
      end)

      reg.call("lines", 1, 1, ->(args : Array(LispValue)) : LispValue do
        path = file_str_arg(args[0], "file:lines")
        raise LispRuntimeError.new("file:lines: file not found: #{path}") unless File.exists?(path)
        LISP.a_to_list(File.read_lines(path).map { |line| LispStr.new(line).as(LispValue) })
      end)

      reg.call("size", 1, 1, ->(args : Array(LispValue)) : LispValue do
        path = file_str_arg(args[0], "file:size")
        raise LispRuntimeError.new("file:size: file not found: #{path}") unless File.exists?(path)
        LispInt.new(File.size(path).to_i64)
      end)
    end

    private def file_str_arg(v : LispValue, who : String) : String
      raise LispRuntimeError.new("#{who}: expected string, got #{v.write_string}") unless v.is_a?(LispStr)
      v.value
    end
  end
end
