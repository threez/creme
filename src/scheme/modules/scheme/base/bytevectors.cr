# ===========================================================================
# Bytevectors (R7RS (scheme base) subset) + byte-oriented ports
# ===========================================================================
#
# R7RS bytevectors are implemented directly on SchemeBlob (values.cr) rather
# than a parallel type — Crystal's Bytes (Slice(UInt8)) already supports
# in-place index mutation, so bytevector-u8-set! needs no new capability on
# the value type itself, only a new builtin. Byte-oriented ports are plain
# SchemePort wrapping an IO::Memory, exactly like string ports, distinguished
# only by the `binary` flag (see SchemePort#binary?) so read-u8/write-u8/
# read-bytevector/etc. know not to UTF-8-decode.

module Scheme::Builtins::Bytevectors
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("bytevector?", min: 1, max: 1)]
  def bytevector_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(args[0].is_a?(SchemeBlob))
  end

  @[Scheme::SchemeFn("bytevector", min: 0, max: -1)]
  def bytevector(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBlob.new(Bytes.new(args.size) { |i| byte_arg(args[i], "bytevector") }).as(SchemeValue)
  end

  @[Scheme::SchemeFn("make-bytevector", min: 1, max: 2)]
  def make_bytevector(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    n = int_arg(args[0], "make-bytevector")
    raise SchemeRuntimeError.new("make-bytevector: length must be non-negative") if n < 0
    fill = args[1]? ? byte_arg(args[1], "make-bytevector") : 0_u8
    SchemeBlob.new(Bytes.new(n.to_i32, fill)).as(SchemeValue)
  end

  @[Scheme::SchemeFn("bytevector-length", min: 1, max: 1)]
  def bytevector_length(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeInt.new(blob_arg(args[0], "bytevector-length").size.to_i64)
  end

  @[Scheme::SchemeFn("bytevector-u8-ref", min: 2, max: 2)]
  def bytevector_u8_ref(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    bytes = blob_arg(args[0], "bytevector-u8-ref")
    idx = int_arg(args[1], "bytevector-u8-ref")
    raise SchemeRuntimeError.new("bytevector-u8-ref: index out of range") if idx < 0 || idx >= bytes.size
    SchemeInt.new(bytes[idx].to_i64)
  end

  @[Scheme::SchemeFn("bytevector-u8-set!", min: 3, max: 3)]
  def bytevector_u8_set(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    bytes = blob_arg(args[0], "bytevector-u8-set!")
    idx = int_arg(args[1], "bytevector-u8-set!")
    raise SchemeRuntimeError.new("bytevector-u8-set!: index out of range") if idx < 0 || idx >= bytes.size
    bytes[idx] = byte_arg(args[2], "bytevector-u8-set!")
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("bytevector-copy", min: 1, max: 3)]
  def bytevector_copy(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    bytes = blob_arg(args[0], "bytevector-copy")
    first, last = seq_range_args(bytes.size, args[1]?, args[2]?, "bytevector-copy")
    SchemeBlob.new(bytes[first...last].dup).as(SchemeValue)
  end

  @[Scheme::SchemeFn("bytevector-copy!", min: 3, max: 5)]
  def bytevector_copy_bang(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    to = blob_arg(args[0], "bytevector-copy!")
    at = int_arg(args[1], "bytevector-copy!")
    from = blob_arg(args[2], "bytevector-copy!")
    first, last = seq_range_args(from.size, args[3]?, args[4]?, "bytevector-copy!")
    count = last - first
    raise SchemeRuntimeError.new("bytevector-copy!: destination too small") if at < 0 || at + count > to.size
    from[first...last].copy_to(to[at, count])
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("bytevector-append", min: 0, max: -1)]
  def bytevector_append(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    total = args.sum { |v| blob_arg(v, "bytevector-append").size }
    result = Bytes.new(total)
    offset = 0
    args.each do |v|
      bytes = blob_arg(v, "bytevector-append")
      bytes.copy_to(result[offset, bytes.size])
      offset += bytes.size
    end
    SchemeBlob.new(result).as(SchemeValue)
  end

  @[Scheme::SchemeFn("utf8->string", min: 1, max: 3)]
  def utf8_to_string(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    bytes = blob_arg(args[0], "utf8->string")
    first, last = seq_range_args(bytes.size, args[1]?, args[2]?, "utf8->string")
    s = String.new(bytes[first...last])
    raise SchemeRuntimeError.new("utf8->string: invalid UTF-8 byte sequence") unless s.valid_encoding?
    SchemeStr.new(s).as(SchemeValue)
  end

  @[Scheme::SchemeFn("string->utf8", min: 1, max: 3)]
  def string_to_utf8(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    s = string_arg(args[0], "string->utf8")
    chars = s.chars
    first, last = seq_range_args(chars.size, args[1]?, args[2]?, "string->utf8")
    SchemeBlob.new(chars[first...last].join.to_slice.dup).as(SchemeValue)
  end

  @[Scheme::SchemeFn("open-input-bytevector", min: 1, max: 1)]
  def open_input_bytevector(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    bytes = blob_arg(args[0], "open-input-bytevector")
    SchemePort.new(IO::Memory.new(bytes), true, false, binary: true).as(SchemeValue)
  end

  @[Scheme::SchemeFn("open-output-bytevector", min: 0, max: 0)]
  def open_output_bytevector(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemePort.new(IO::Memory.new, false, true, binary: true).as(SchemeValue)
  end

  @[Scheme::SchemeFn("get-output-bytevector", min: 1, max: 1)]
  def get_output_bytevector(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    p = port_arg(args[0], "get-output-bytevector")
    io = p.io
    raise SchemeRuntimeError.new("get-output-bytevector: expected a bytevector output port") unless io.is_a?(IO::Memory)
    SchemeBlob.new(io.to_slice.dup).as(SchemeValue)
  end

  @[Scheme::SchemeFn("read-u8", min: 0, max: 1)]
  def read_u8(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    p = interp.input_port_arg(args[0]?, "read-u8")
    byte = p.io.read_byte
    byte ? SchemeInt.new(byte.to_i64).as(SchemeValue) : EOF.as(SchemeValue)
  end

  @[Scheme::SchemeFn("peek-u8", min: 0, max: 1)]
  def peek_u8(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    p = interp.input_port_arg(args[0]?, "peek-u8")
    bytes = p.io.peek
    (bytes.nil? || bytes.empty?) ? EOF.as(SchemeValue) : SchemeInt.new(bytes[0].to_i64).as(SchemeValue)
  end

  @[Scheme::SchemeFn("u8-ready?", min: 0, max: 1)]
  def u8_ready_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    p = interp.input_port_arg(args[0]?, "u8-ready?")
    bytes = p.io.peek
    SchemeBool.of(!bytes.nil? && !bytes.empty?)
  end

  @[Scheme::SchemeFn("write-u8", min: 1, max: 2)]
  def write_u8(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    byte = byte_arg(args[0], "write-u8")
    p = port_arg(args[1]? || raise(SchemeRuntimeError.new("write-u8: expects a port")), "write-u8")
    raise SchemeRuntimeError.new("write-u8: port is closed") if p.closed?
    p.io.write_byte(byte)
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("read-bytevector", min: 1, max: 2)]
  def read_bytevector(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    n = int_arg(args[0], "read-bytevector")
    raise SchemeRuntimeError.new("read-bytevector: count must be non-negative") if n < 0
    p = interp.input_port_arg(args[1]?, "read-bytevector")
    buf = Bytes.new(n)
    read = p.io.read(buf)
    read == 0 && n > 0 ? EOF.as(SchemeValue) : SchemeBlob.new(buf[0, read].dup).as(SchemeValue)
  end

  @[Scheme::SchemeFn("read-bytevector!", min: 1, max: 4)]
  def read_bytevector_bang(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    bytes = blob_arg(args[0], "read-bytevector!")
    p = interp.input_port_arg(args[1]?, "read-bytevector!")
    first, last = seq_range_args(bytes.size, args[2]?, args[3]?, "read-bytevector!")
    read = p.io.read(bytes[first...last])
    read == 0 && last > first ? EOF.as(SchemeValue) : SchemeInt.new(read.to_i64).as(SchemeValue)
  end

  @[Scheme::SchemeFn("write-bytevector", min: 1, max: 4)]
  def write_bytevector(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    bytes = blob_arg(args[0], "write-bytevector")
    p = port_arg(args[1]? || raise(SchemeRuntimeError.new("write-bytevector: expects a port")), "write-bytevector")
    raise SchemeRuntimeError.new("write-bytevector: port is closed") if p.closed?
    first, last = seq_range_args(bytes.size, args[2]?, args[3]?, "write-bytevector")
    p.io.write(bytes[first...last])
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("binary-port?", min: 1, max: 1)]
  def binary_port_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(args[0].is_a?(SchemePort) && args[0].as(SchemePort).binary?)
  end

  @[Scheme::SchemeFn("textual-port?", min: 1, max: 1)]
  def textual_port_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(args[0].is_a?(SchemePort) && !args[0].as(SchemePort).binary?)
  end

  @[Scheme::SchemeFn("input-port-open?", min: 1, max: 1)]
  def input_port_open_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    p = port_arg(args[0], "input-port-open?")
    SchemeBool.of(p.input? && !p.closed?)
  end

  @[Scheme::SchemeFn("output-port-open?", min: 1, max: 1)]
  def output_port_open_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    p = port_arg(args[0], "output-port-open?")
    SchemeBool.of(p.output? && !p.closed?)
  end

  @[Scheme::SchemeFn("char-ready?", min: 0, max: 1)]
  def char_ready_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    p = interp.input_port_arg(args[0]?, "char-ready?")
    bytes = p.io.peek
    SchemeBool.of(!bytes.nil? && !bytes.empty?)
  end

  # (call-with-port port proc) applies proc to port, closing port when
  # proc returns (or raises) — a plain ensure-based close is sufficient
  # here (no dynamic-wind dependency: this doesn't need to survive a
  # continuation re-entering the dynamic extent from outside, only to
  # clean up on ordinary return/unwind).
  @[Scheme::SchemeFn("call-with-port", min: 2, max: 2)]
  def call_with_port(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    p = port_arg(args[0], "call-with-port")
    proc = args[1]
    begin
      interp.apply(proc, [p.as(SchemeValue)])
    ensure
      p.io.close unless p.closed?
      p.closed = true
    end
  end
end

module Scheme
  class Interpreter
    private def install_bytevectors(env : Env) : Nil
      register_module(Scheme::Builtins::Bytevectors, env)
    end
  end
end
