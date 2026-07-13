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

module Scheme
  class Interpreter
    # ameba:disable Metrics/CyclomaticComplexity
    private def install_bytevectors(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(SchemeValue) -> SchemeValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      reg.call("bytevector?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(args[0].is_a?(SchemeBlob)) })

      reg.call("bytevector", 0, -1, ->(args : Array(SchemeValue)) : SchemeValue do
        SchemeBlob.new(Bytes.new(args.size) { |i| byte_arg(args[i], "bytevector") }).as(SchemeValue)
      end)

      reg.call("make-bytevector", 1, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        n = int_arg(args[0], "make-bytevector")
        raise SchemeRuntimeError.new("make-bytevector: length must be non-negative") if n < 0
        fill = args[1]? ? byte_arg(args[1], "make-bytevector") : 0_u8
        SchemeBlob.new(Bytes.new(n.to_i32, fill)).as(SchemeValue)
      end)

      reg.call("bytevector-length", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        SchemeInt.new(blob_arg(args[0], "bytevector-length").size.to_i64)
      end)

      reg.call("bytevector-u8-ref", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        bytes = blob_arg(args[0], "bytevector-u8-ref")
        idx = int_arg(args[1], "bytevector-u8-ref")
        raise SchemeRuntimeError.new("bytevector-u8-ref: index out of range") if idx < 0 || idx >= bytes.size
        SchemeInt.new(bytes[idx].to_i64)
      end)

      reg.call("bytevector-u8-set!", 3, 3, ->(args : Array(SchemeValue)) : SchemeValue do
        bytes = blob_arg(args[0], "bytevector-u8-set!")
        idx = int_arg(args[1], "bytevector-u8-set!")
        raise SchemeRuntimeError.new("bytevector-u8-set!: index out of range") if idx < 0 || idx >= bytes.size
        bytes[idx] = byte_arg(args[2], "bytevector-u8-set!")
        NIL.as(SchemeValue)
      end)

      reg.call("bytevector-copy", 1, 3, ->(args : Array(SchemeValue)) : SchemeValue do
        bytes = blob_arg(args[0], "bytevector-copy")
        first, last = seq_range_args(bytes.size, args[1]?, args[2]?, "bytevector-copy")
        SchemeBlob.new(bytes[first...last].dup).as(SchemeValue)
      end)

      reg.call("bytevector-copy!", 3, 5, ->(args : Array(SchemeValue)) : SchemeValue do
        to = blob_arg(args[0], "bytevector-copy!")
        at = int_arg(args[1], "bytevector-copy!")
        from = blob_arg(args[2], "bytevector-copy!")
        first, last = seq_range_args(from.size, args[3]?, args[4]?, "bytevector-copy!")
        count = last - first
        raise SchemeRuntimeError.new("bytevector-copy!: destination too small") if at < 0 || at + count > to.size
        from[first...last].copy_to(to[at, count])
        NIL.as(SchemeValue)
      end)

      reg.call("bytevector-append", 0, -1, ->(args : Array(SchemeValue)) : SchemeValue do
        total = args.sum { |v| blob_arg(v, "bytevector-append").size }
        result = Bytes.new(total)
        offset = 0
        args.each do |v|
          bytes = blob_arg(v, "bytevector-append")
          bytes.copy_to(result[offset, bytes.size])
          offset += bytes.size
        end
        SchemeBlob.new(result).as(SchemeValue)
      end)

      reg.call("utf8->string", 1, 3, ->(args : Array(SchemeValue)) : SchemeValue do
        bytes = blob_arg(args[0], "utf8->string")
        first, last = seq_range_args(bytes.size, args[1]?, args[2]?, "utf8->string")
        s = String.new(bytes[first...last])
        raise SchemeRuntimeError.new("utf8->string: invalid UTF-8 byte sequence") unless s.valid_encoding?
        SchemeStr.new(s).as(SchemeValue)
      end)

      reg.call("string->utf8", 1, 3, ->(args : Array(SchemeValue)) : SchemeValue do
        s = string_arg(args[0], "string->utf8")
        chars = s.chars
        first, last = seq_range_args(chars.size, args[1]?, args[2]?, "string->utf8")
        SchemeBlob.new(chars[first...last].join.to_slice.dup).as(SchemeValue)
      end)

      # ---- Byte ports ----
      reg.call("open-input-bytevector", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        bytes = blob_arg(args[0], "open-input-bytevector")
        SchemePort.new(IO::Memory.new(bytes), true, false, binary: true).as(SchemeValue)
      end)

      reg.call("open-output-bytevector", 0, 0, ->(_args : Array(SchemeValue)) : SchemeValue do
        SchemePort.new(IO::Memory.new, false, true, binary: true).as(SchemeValue)
      end)

      reg.call("get-output-bytevector", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        p = port_arg(args[0], "get-output-bytevector")
        io = p.io
        raise SchemeRuntimeError.new("get-output-bytevector: expected a bytevector output port") unless io.is_a?(IO::Memory)
        SchemeBlob.new(io.to_slice.dup).as(SchemeValue)
      end)

      reg.call("read-u8", 0, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        p = input_port_arg(args[0]?, "read-u8")
        byte = p.io.read_byte
        byte ? SchemeInt.new(byte.to_i64).as(SchemeValue) : EOF.as(SchemeValue)
      end)

      reg.call("peek-u8", 0, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        p = input_port_arg(args[0]?, "peek-u8")
        bytes = p.io.peek
        (bytes.nil? || bytes.empty?) ? EOF.as(SchemeValue) : SchemeInt.new(bytes[0].to_i64).as(SchemeValue)
      end)

      reg.call("u8-ready?", 0, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        p = input_port_arg(args[0]?, "u8-ready?")
        bytes = p.io.peek
        SchemeBool.of(!bytes.nil? && !bytes.empty?)
      end)

      reg.call("write-u8", 1, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        byte = byte_arg(args[0], "write-u8")
        p = port_arg(args[1]? || raise(SchemeRuntimeError.new("write-u8: expects a port")), "write-u8")
        raise SchemeRuntimeError.new("write-u8: port is closed") if p.closed?
        p.io.write_byte(byte)
        NIL.as(SchemeValue)
      end)

      reg.call("read-bytevector", 1, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        n = int_arg(args[0], "read-bytevector")
        raise SchemeRuntimeError.new("read-bytevector: count must be non-negative") if n < 0
        p = input_port_arg(args[1]?, "read-bytevector")
        buf = Bytes.new(n)
        read = p.io.read(buf)
        read == 0 && n > 0 ? EOF.as(SchemeValue) : SchemeBlob.new(buf[0, read].dup).as(SchemeValue)
      end)

      reg.call("read-bytevector!", 1, 4, ->(args : Array(SchemeValue)) : SchemeValue do
        bytes = blob_arg(args[0], "read-bytevector!")
        p = input_port_arg(args[1]?, "read-bytevector!")
        first, last = seq_range_args(bytes.size, args[2]?, args[3]?, "read-bytevector!")
        read = p.io.read(bytes[first...last])
        read == 0 && last > first ? EOF.as(SchemeValue) : SchemeInt.new(read.to_i64).as(SchemeValue)
      end)

      reg.call("write-bytevector", 1, 4, ->(args : Array(SchemeValue)) : SchemeValue do
        bytes = blob_arg(args[0], "write-bytevector")
        p = port_arg(args[1]? || raise(SchemeRuntimeError.new("write-bytevector: expects a port")), "write-bytevector")
        raise SchemeRuntimeError.new("write-bytevector: port is closed") if p.closed?
        first, last = seq_range_args(bytes.size, args[2]?, args[3]?, "write-bytevector")
        p.io.write(bytes[first...last])
        NIL.as(SchemeValue)
      end)

      # ---- Port predicates ----
      reg.call("binary-port?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(args[0].is_a?(SchemePort) && args[0].as(SchemePort).binary?) })
      reg.call("textual-port?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(args[0].is_a?(SchemePort) && !args[0].as(SchemePort).binary?) })

      reg.call("input-port-open?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        p = port_arg(args[0], "input-port-open?")
        SchemeBool.of(p.input? && !p.closed?)
      end)

      reg.call("output-port-open?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        p = port_arg(args[0], "output-port-open?")
        SchemeBool.of(p.output? && !p.closed?)
      end)

      reg.call("char-ready?", 0, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        p = input_port_arg(args[0]?, "char-ready?")
        bytes = p.io.peek
        SchemeBool.of(!bytes.nil? && !bytes.empty?)
      end)

      # (call-with-port port proc) applies proc to port, closing port when
      # proc returns (or raises) — a plain ensure-based close is sufficient
      # here (no dynamic-wind dependency: this doesn't need to survive a
      # continuation re-entering the dynamic extent from outside, only to
      # clean up on ordinary return/unwind).
      reg.call("call-with-port", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        p = port_arg(args[0], "call-with-port")
        proc = args[1]
        begin
          apply(proc, [p.as(SchemeValue)])
        ensure
          p.io.close unless p.closed?
          p.closed = true
        end
      end)
    end

    private def byte_arg(v : SchemeValue, who : String) : UInt8
      n = int_arg(v, who)
      raise SchemeRuntimeError.new("#{who}: expected a byte (0..255), got #{v.write_string}") unless n >= 0 && n <= 255
      n.to_u8
    end
  end
end
