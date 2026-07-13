# ===========================================================================
# file module: whole-file convenience helpers plus R7RS port-based file I/O
# ===========================================================================

module Scheme
  class Interpreter
    private def install_file(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(SchemeValue) -> SchemeValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      reg.call("file-read", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        path = file_str_arg(args[0], "file-read")
        raise SchemeFileError.new("file-read: file not found: #{path}") unless File.exists?(path)
        begin
          SchemeStr.new(File.read(path))
        rescue ex : Exception
          raise SchemeFileError.new("file-read: #{ex.message}")
        end
      end)

      reg.call("file-write", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        path = file_str_arg(args[0], "file-write")
        content = file_str_arg(args[1], "file-write")
        begin
          File.write(path, content)
        rescue ex : Exception
          raise SchemeFileError.new("file-write: #{ex.message}")
        end
        NIL.as(SchemeValue)
      end)

      reg.call("file-append", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        path = file_str_arg(args[0], "file-append")
        content = file_str_arg(args[1], "file-append")
        begin
          File.open(path, "a", &.print(content))
        rescue ex : Exception
          raise SchemeFileError.new("file-append: #{ex.message}")
        end
        NIL.as(SchemeValue)
      end)

      reg.call("file-exists?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        SchemeBool.of(File.exists?(file_str_arg(args[0], "file-exists?")))
      end)

      reg.call("delete-file", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        path = file_str_arg(args[0], "delete-file")
        raise SchemeFileError.new("delete-file: file not found: #{path}") unless File.exists?(path)
        begin
          File.delete(path)
        rescue ex : Exception
          raise SchemeFileError.new("delete-file: #{ex.message}")
        end
        NIL.as(SchemeValue)
      end)

      reg.call("file-lines", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        path = file_str_arg(args[0], "file-lines")
        raise SchemeFileError.new("file-lines: file not found: #{path}") unless File.exists?(path)
        Scheme.a_to_list(File.read_lines(path).map { |line| SchemeStr.new(line).as(SchemeValue) })
      end)

      reg.call("file-size", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        path = file_str_arg(args[0], "file-size")
        raise SchemeFileError.new("file-size: file not found: #{path}") unless File.exists?(path)
        SchemeInt.new(File.size(path).to_i64)
      end)

      # ---- R7RS port-based file I/O ----

      reg.call("open-input-file", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        path = file_str_arg(args[0], "open-input-file")
        raise SchemeFileError.new("open-input-file: file not found: #{path}") unless File.exists?(path)
        SchemePort.new(File.open(path, "r"), true, false)
      end)

      reg.call("open-output-file", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        path = file_str_arg(args[0], "open-output-file")
        SchemePort.new(File.open(path, "w"), false, true)
      end)

      reg.call("open-binary-input-file", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        path = file_str_arg(args[0], "open-binary-input-file")
        raise SchemeFileError.new("open-binary-input-file: file not found: #{path}") unless File.exists?(path)
        SchemePort.new(File.open(path, "rb"), true, false, true)
      end)

      reg.call("open-binary-output-file", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        path = file_str_arg(args[0], "open-binary-output-file")
        SchemePort.new(File.open(path, "wb"), false, true, true)
      end)

      reg.call("call-with-input-file", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        path = file_str_arg(args[0], "call-with-input-file")
        raise SchemeFileError.new("call-with-input-file: file not found: #{path}") unless File.exists?(path)
        proc = args[1]
        File.open(path, "r") do |io|
          port = SchemePort.new(io, true, false)
          result = apply(proc, [port.as(SchemeValue)])
          port.closed = true
          result
        end
      end)

      reg.call("call-with-output-file", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        path = file_str_arg(args[0], "call-with-output-file")
        proc = args[1]
        File.open(path, "w") do |io|
          port = SchemePort.new(io, false, true)
          result = apply(proc, [port.as(SchemeValue)])
          port.closed = true
          result
        end
      end)

      reg.call("with-input-from-file", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        path = file_str_arg(args[0], "with-input-from-file")
        raise SchemeFileError.new("with-input-from-file: file not found: #{path}") unless File.exists?(path)
        thunk = args[1]
        previous = stdin
        File.open(path, "r") do |io|
          self.stdin = io
          begin
            apply(thunk, [] of SchemeValue)
          ensure
            self.stdin = previous
          end
        end
      end)

      reg.call("with-output-to-file", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        path = file_str_arg(args[0], "with-output-to-file")
        thunk = args[1]
        previous = stdout
        File.open(path, "w") do |io|
          self.stdout = io
          begin
            apply(thunk, [] of SchemeValue)
          ensure
            self.stdout = previous
          end
        end
      end)
    end

    private def file_str_arg(v : SchemeValue, who : String) : String
      raise SchemeRuntimeError.new("#{who}: expected string, got #{v.write_string}") unless v.is_a?(SchemeStr)
      v.value
    end

    # (scheme load)'s load procedure: reads and evaluates filename's forms
    # sequentially against environment-specifier (defaulting to
    # (interaction-environment), i.e. @global, when omitted), same
    # filename-resolution convention as include/include-ci (relative to
    # @load_dirs.last, pushed for the duration so a loaded file's own
    # relative includes/loads resolve correctly).
    private def install_load(env : Env) : Nil
      env.define("load", Builtin.new("load", 1, 2) do |args|
        path_arg = args[0]
        raise SchemeRuntimeError.new("load: expected string, got #{path_arg.write_string}") unless path_arg.is_a?(SchemeStr)
        target_env = args.size == 2 ? environment_specifier_arg(args[1], "load") : @global

        dir = @load_dirs.last?
        path = dir ? File.join(dir, path_arg.value) : path_arg.value
        raise SchemeRuntimeError.new("load: #{path_arg.value}: file not found") unless File.exists?(path)
        resolved = File.realpath(path)
        forms = Reader.read_all(File.read(resolved), resolved)
        @load_dirs << File.dirname(resolved)
        begin
          result : SchemeValue = NIL
          forms.each { |form| result = eval(form, target_env) }
          result
        ensure
          @load_dirs.pop
        end
      end)
    end
  end
end
