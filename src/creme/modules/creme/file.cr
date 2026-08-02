# ===========================================================================
# file module: R7RS port-based file I/O (FileLibrary) plus creme-only
# whole-file convenience helpers (FileExtra)
# ===========================================================================
#
# FileLibrary holds exactly the procedures R7RS's (scheme file) specifies —
# so (scheme file) (modules/scheme/file.cr) registers it directly and its
# export list is derived, no hand-maintained subset constant. FileExtra
# holds this project's non-standard whole-file conveniences
# (file-read/file-write/file-append/file-lines/file-size/current-directory);
# (creme file) registers BOTH, so it stays the richer superset.

module Creme::Builtins::FileLibrary
  extend self
  include Creme::BuiltinHelpers

  @[Creme::SchemeFn("file-exists?", min: 1, max: 1)]
  def file_exists_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(File.exists?(file_str_arg(args[0], "file-exists?")))
  end

  @[Creme::SchemeFn("delete-file", min: 1, max: 1)]
  def delete_file(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    path = file_str_arg(args[0], "delete-file")
    raise SchemeFileError.new("delete-file: file not found: #{path}") unless File.exists?(path)
    begin
      File.delete(path)
    rescue ex : Exception
      raise SchemeFileError.new("delete-file: #{ex.message}")
    end
    NIL.as(SchemeValue)
  end

  @[Creme::SchemeFn("open-input-file", min: 1, max: 1)]
  def open_input_file(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    path = file_str_arg(args[0], "open-input-file")
    raise SchemeFileError.new("open-input-file: file not found: #{path}") unless File.exists?(path)
    SchemePort.new(File.open(path, "r"), true, false)
  end

  @[Creme::SchemeFn("open-output-file", min: 1, max: 1)]
  def open_output_file(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    path = file_str_arg(args[0], "open-output-file")
    SchemePort.new(File.open(path, "w"), false, true)
  end

  @[Creme::SchemeFn("open-binary-input-file", min: 1, max: 1)]
  def open_binary_input_file(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    path = file_str_arg(args[0], "open-binary-input-file")
    raise SchemeFileError.new("open-binary-input-file: file not found: #{path}") unless File.exists?(path)
    SchemePort.new(File.open(path, "rb"), true, false, true)
  end

  @[Creme::SchemeFn("open-binary-output-file", min: 1, max: 1)]
  def open_binary_output_file(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    path = file_str_arg(args[0], "open-binary-output-file")
    SchemePort.new(File.open(path, "wb"), false, true, true)
  end

  @[Creme::SchemeFn("call-with-input-file", min: 2, max: 2)]
  def call_with_input_file(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    path = file_str_arg(args[0], "call-with-input-file")
    raise SchemeFileError.new("call-with-input-file: file not found: #{path}") unless File.exists?(path)
    proc = args[1]
    File.open(path, "r") do |io|
      port = SchemePort.new(io, true, false)
      result = interp.apply(proc, [port.as(SchemeValue)])
      port.closed = true
      result
    end
  end

  @[Creme::SchemeFn("call-with-output-file", min: 2, max: 2)]
  def call_with_output_file(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    path = file_str_arg(args[0], "call-with-output-file")
    proc = args[1]
    File.open(path, "w") do |io|
      port = SchemePort.new(io, false, true)
      result = interp.apply(proc, [port.as(SchemeValue)])
      port.closed = true
      result
    end
  end

  @[Creme::SchemeFn("with-input-from-file", min: 2, max: 2)]
  def with_input_from_file(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    path = file_str_arg(args[0], "with-input-from-file")
    raise SchemeFileError.new("with-input-from-file: file not found: #{path}") unless File.exists?(path)
    thunk = args[1]
    previous = interp.stdin
    File.open(path, "r") do |io|
      interp.stdin = io
      begin
        interp.apply(thunk, [] of SchemeValue)
      ensure
        interp.stdin = previous
      end
    end
  end

  @[Creme::SchemeFn("with-output-to-file", min: 2, max: 2)]
  def with_output_to_file(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    path = file_str_arg(args[0], "with-output-to-file")
    thunk = args[1]
    previous = interp.stdout
    File.open(path, "w") do |io|
      interp.stdout = io
      begin
        interp.apply(thunk, [] of SchemeValue)
      ensure
        interp.stdout = previous
      end
    end
  end

  private def file_str_arg(v : SchemeValue, who : String) : String
    raise SchemeRuntimeError.new("#{who}: expected string, got #{v.write_string}") unless v.is_a?(SchemeStr)
    v.value
  end
end

# creme-only whole-file conveniences, beyond R7RS's (scheme file) contract.
module Creme::Builtins::FileExtra
  extend self
  include Creme::BuiltinHelpers

  @[Creme::SchemeFn("file-read", min: 1, max: 1)]
  def file_read(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    path = file_str_arg(args[0], "file-read")
    raise SchemeFileError.new("file-read: file not found: #{path}") unless File.exists?(path)
    SchemeStr.new(File.read(path))
  rescue ex : Exception
    raise SchemeFileError.new("file-read: #{ex.message}")
  end

  @[Creme::SchemeFn("file-write", min: 2, max: 2)]
  def file_write(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    path = file_str_arg(args[0], "file-write")
    content = file_str_arg(args[1], "file-write")
    begin
      File.write(path, content)
    rescue ex : Exception
      raise SchemeFileError.new("file-write: #{ex.message}")
    end
    NIL.as(SchemeValue)
  end

  @[Creme::SchemeFn("file-append", min: 2, max: 2)]
  def file_append(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    path = file_str_arg(args[0], "file-append")
    content = file_str_arg(args[1], "file-append")
    begin
      File.open(path, "a", &.print(content))
    rescue ex : Exception
      raise SchemeFileError.new("file-append: #{ex.message}")
    end
    NIL.as(SchemeValue)
  end

  # (current-directory) -> the process's current working directory
  # (absolute) — e.g. so a script can turn an absolute path it was handed
  # (a SourcePos.file, a profiler entry, ...) back into one relative to
  # where it was invoked from for display purposes.
  @[Creme::SchemeFn("current-directory", min: 0, max: 0)]
  def current_directory(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeStr.new(Dir.current).as(SchemeValue)
  end

  @[Creme::SchemeFn("file-lines", min: 1, max: 1)]
  def file_lines(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    path = file_str_arg(args[0], "file-lines")
    raise SchemeFileError.new("file-lines: file not found: #{path}") unless File.exists?(path)
    Creme.a_to_list(File.read_lines(path).map { |line| SchemeStr.new(line).as(SchemeValue) })
  end

  @[Creme::SchemeFn("file-size", min: 1, max: 1)]
  def file_size(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    path = file_str_arg(args[0], "file-size")
    raise SchemeFileError.new("file-size: file not found: #{path}") unless File.exists?(path)
    SchemeInt.new(File.size(path).to_i64)
  end

  private def file_str_arg(v : SchemeValue, who : String) : String
    raise SchemeRuntimeError.new("#{who}: expected string, got #{v.write_string}") unless v.is_a?(SchemeStr)
    v.value
  end
end

module Creme
  class Interpreter
    register_library ["creme", "builtin", "file"] do |env|
      register_module(Creme::Builtins::FileLibrary, env) +
        register_module(Creme::Builtins::FileExtra, env)
    end
  end
end
