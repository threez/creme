# ===========================================================================
# (scheme base): I/O, ports, string ports
# ===========================================================================
#
# (scheme write)'s display/write/write-simple/write-shared live in
# Creme::R7RS::WriteLibrary (base/write.cr); `read` lives in
# Creme::R7RS::ReadLibrary ((scheme read), modules/scheme/read.cr).

module Creme::R7RS::Io
  extend self
  include Creme::BuiltinHelpers

  @[Creme::SchemeFn("newline", min: 0, max: 1)]
  def newline(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    interp.emit("\n", args[0]?, "newline")
    NIL.as(SchemeValue)
  end

  @[Creme::SchemeFn("flush-output-port", min: 0, max: 1)]
  def flush_output_port(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    p = args[0]? ? port_arg(args[0], "flush-output-port") : interp.current_output_port.value.as(SchemePort)
    raise SchemeRuntimeError.new("flush-output-port: expected an output port") unless p.output?
    p.io.flush
    NIL.as(SchemeValue)
  end

  @[Creme::SchemeFn("open-input-string", min: 1, max: 1)]
  def open_input_string(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    s = string_arg(args[0], "open-input-string")
    SchemePort.new(IO::Memory.new(s), true, false).as(SchemeValue)
  end

  @[Creme::SchemeFn("open-output-string", min: 0, max: 0)]
  def open_output_string(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemePort.new(IO::Memory.new, false, true).as(SchemeValue)
  end

  @[Creme::SchemeFn("get-output-string", min: 1, max: 1)]
  def get_output_string(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    p = port_arg(args[0], "get-output-string")
    io = p.io
    raise SchemeRuntimeError.new("get-output-string: expected a string output port") unless io.is_a?(IO::Memory)
    SchemeStr.new(io.to_s).as(SchemeValue)
  end

  @[Creme::SchemeFn("port?", min: 1, max: 1)]
  def port_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(args[0].is_a?(SchemePort))
  end

  @[Creme::SchemeFn("input-port?", min: 1, max: 1)]
  def input_port_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(args[0].is_a?(SchemePort) && args[0].as(SchemePort).input?)
  end

  @[Creme::SchemeFn("output-port?", min: 1, max: 1)]
  def output_port_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(args[0].is_a?(SchemePort) && args[0].as(SchemePort).output?)
  end

  @[Creme::SchemeFn("eof-object?", min: 1, max: 1)]
  def eof_object_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(args[0].is_a?(SchemeEof))
  end

  @[Creme::SchemeFn("eof-object", min: 0, max: 0)]
  def eof_object(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    EOF.as(SchemeValue)
  end

  @[Creme::SchemeFn("close-port", min: 1, max: 1)]
  def close_port(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    p = port_arg(args[0], "close-port")
    p.io.close unless p.closed?
    p.closed = true
    NIL.as(SchemeValue)
  end

  @[Creme::SchemeFn("close-input-port", min: 1, max: 1)]
  def close_input_port(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    p = port_arg(args[0], "close-input-port")
    p.io.close unless p.closed?
    p.closed = true
    NIL.as(SchemeValue)
  end

  @[Creme::SchemeFn("close-output-port", min: 1, max: 1)]
  def close_output_port(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    p = port_arg(args[0], "close-output-port")
    p.io.close unless p.closed?
    p.closed = true
    NIL.as(SchemeValue)
  end

  @[Creme::SchemeFn("read-char", min: 0, max: 1)]
  def read_char(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    p = interp.input_port_arg(args[0]?, "read-char")
    c = p.io.read_char
    c ? SchemeChar.new(c).as(SchemeValue) : EOF.as(SchemeValue)
  end

  @[Creme::SchemeFn("peek-char", min: 0, max: 1)]
  def peek_char(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    p = interp.input_port_arg(args[0]?, "peek-char")
    c = p.io.peek
    (c.nil? || c.empty?) ? EOF.as(SchemeValue) : SchemeChar.new(c[0].chr).as(SchemeValue)
  end

  @[Creme::SchemeFn("read-line", min: 0, max: 1)]
  def read_line(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    p = interp.input_port_arg(args[0]?, "read-line")
    line = p.io.gets(chomp: true)
    line ? SchemeStr.new(line).as(SchemeValue) : EOF.as(SchemeValue)
  end

  @[Creme::SchemeFn("read-string", min: 1, max: 2)]
  def read_string(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    n = int_arg(args[0], "read-string")
    raise SchemeRuntimeError.new("read-string: count must be non-negative") if n < 0
    p = interp.input_port_arg(args[1]?, "read-string")
    buf = Bytes.new(n)
    read = p.io.read_fully?(buf)
    read ? SchemeStr.new(String.new(buf)).as(SchemeValue) : EOF.as(SchemeValue)
  end

  @[Creme::SchemeFn("write-char", min: 1, max: 2)]
  def write_char(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    c = args[0]
    raise SchemeRuntimeError.new("write-char: expected char, got #{c.write_string}") unless c.is_a?(SchemeChar)
    interp.emit(c.value.to_s, args[1]?, "write-char")
    NIL.as(SchemeValue)
  end

  @[Creme::SchemeFn("write-string", min: 1, max: 2)]
  def write_string(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    s = args[0]
    raise SchemeRuntimeError.new("write-string: expected string, got #{s.write_string}") unless s.is_a?(SchemeStr)
    interp.emit(s.value, args[1]?, "write-string")
    NIL.as(SchemeValue)
  end
end

module Creme
  class Interpreter
    private def install_io(env : Env) : Array(String)
      # current-*-port are real R7RS parameter objects (not zero-arg
      # builtins) — bound directly so both `(current-output-port)` (apply
      # on a SchemeParameter returns .value, see apply) and
      # `(parameterize ((current-output-port p)) ...)` (which needs the
      # identifier itself bound to the parameter, not a procedure that
      # constructs one) work. See Interpreter#initialize for how their
      # default value stays in sync with stdout=/stdin=/stderr=.
      env.define("current-output-port", current_output_port)
      env.define("current-input-port", current_input_port)
      env.define("current-error-port", current_error_port)

      register_module(Creme::R7RS::Io, env)
    end

    # Writes to an explicit port argument when given (as display/write/
    # newline/write-char/write-string's optional trailing port accepts),
    # otherwise falls back to current_output_port's current value — a real
    # R7RS parameter, so `(parameterize ((current-output-port p)) ...)`
    # genuinely redirects this default; stdout= keeps working too, since
    # it resyncs that same parameter's default SchemePort in place.
    def emit(s : String, port : SchemeValue? = nil, who : String = "write") : Nil
      target = port || current_output_port.value
      raise SchemeRuntimeError.new("#{who}: expected an output port, got #{target.write_string}") unless target.is_a?(SchemePort)
      raise SchemeRuntimeError.new("#{who}: port is closed") if target.closed?
      target.io.print(s)
    end

    def input_port_arg(v : SchemeValue?, who : String) : SchemePort
      p = v ? port_arg(v, who) : current_input_port.value.as(SchemePort)
      raise SchemeRuntimeError.new("#{who}: expected an input port") unless p.input?
      raise SchemeRuntimeError.new("#{who}: port is closed") if p.closed?
      p
    end
  end
end
