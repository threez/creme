# ===========================================================================
# ChunkDeserializer: the inverse of ChunkSerializer's "ICE" format.
# ===========================================================================
#
# This is the piece the self-hosting bootstrap plan actually needs long-
# term: a way for running Scheme code to hand the VM a freshly built chunk
# (as raw bytes) and have it turned into something runnable, without going
# through Interpreter#analyze/BytecodeCompiler at all. See
# Creme::Builtins::BootstrapLibrary (modules/creme/bootstrap.cr) for the
# `load-chunk-bytes` builtin that exposes this to Scheme.
#
# Builtin constants (TAG_BUILTIN) are resolved by name against the env
# passed to `deserialize` — this only works for names already bound there
# (ordinarily the global/base env, where every real builtin lives), and
# raises if the name is unknown, exactly like a bad GetGlobal would.
module Creme
  module ChunkDeserializer
    class FormatError < Exception
    end

    private DUMMY_QQ_NODE = LiteralNode.new(NIL)

    def self.deserialize(bytes : Bytes, env : Env) : Chunk
      io = IO::Memory.new(bytes)
      magic_buf = Bytes.new(4)
      io.read_fully(magic_buf)
      magic = String.new(magic_buf)
      # The version is the 4th magic byte ('0' + version); bytes 0..2 are the
      # fixed "ICE" prefix. A mismatch on either is the same "re-emit this"
      # signal (a stale v1 blob fails the version check here).
      unless magic[0, 3] == ChunkSerializer::MAGIC_PREFIX
        raise FormatError.new("chunk_deserializer: bad magic #{magic.inspect}, expected #{ChunkSerializer::MAGIC.inspect}")
      end
      version = magic_buf[3].to_i - '0'.ord
      unless version == ChunkSerializer::FORMAT_VERSION
        raise FormatError.new("chunk_deserializer: format version #{version} (expected #{ChunkSerializer::FORMAT_VERSION}) -- re-emit this chunk with the current creme/icecreme")
      end
      # Everything after the 4-byte magic is a zstd frame of the body (see
      # ChunkSerializer.serialize). Decompress it and read the body from there.
      # A stale UNcompressed "ICE1" body fails cleanly here (not a zstd frame).
      body = Creme::Builtins::ZstdLibrary.decompress_bytes(bytes[4, bytes.size - 4], "chunk_deserializer")
      io = IO::Memory.new(body)
      strings = read_string_pool(io)
      read_required_families(io, strings) # not yet consumed by any caller; just skip past it
      read_chunk(io, env, strings)
    end

    # The global string pool: every distinct string/symbol the chunk tree
    # references, each written once here and referenced everywhere else by a
    # u24 index -- see ChunkSerializer's StringInterner.
    private def self.read_string_pool(io : IO) : Array(String)
      count = read_i32(io)
      Array(String).new(count) { read_pool_string(io) }
    end

    private def self.read_pool_string(io : IO) : String
      len = read_i32(io)
      buf = Bytes.new(len)
      io.read_fully(buf)
      String.new(buf)
    end

    # The inverse of ChunkSerializer.write_int_str: TAG_INT/TAG_RATIONAL's
    # payload is a decimal ASCII string (same length-prefixed shape as any
    # other pool string), parsed once, here, at chunk-load time — never
    # re-parsed per reference. Always via BigInt so a single code path
    # handles both small and oversized values, then demoted to Int64 when
    # it fits (RatInt's canonicalization invariant).
    private def self.read_int_str(io : IO) : RatInt
      Creme.rat_demote(BigInt.new(read_pool_string(io)))
    end

    # Reads (and discards) the "required families" metadata section that sits
    # between the string pool and the chunk body — see ChunkSerializer.serialize.
    # Nothing reads this yet, but it must be consumed here so the chunk body
    # that immediately follows it is read from the right offset.
    private def self.read_required_families(io : IO, strings : Array(String)) : Array(String)
      count = read_i32(io)
      Array(String).new(count) { strings[read_u24(io)] }
    end

    private def self.read_byte!(io : IO) : UInt8
      io.read_byte || raise FormatError.new("chunk_deserializer: unexpected end of input")
    end

    private def self.read_i32(io : IO) : Int32
      io.read_bytes(Int32, IO::ByteFormat::LittleEndian)
    end

    private def self.read_i64(io : IO) : Int64
      io.read_bytes(Int64, IO::ByteFormat::LittleEndian)
    end

    # Little-endian unsigned 24-/16-bit reads -- the inverse of
    # ChunkSerializer's write_u24/write_u16 (pool indices, position fields).
    private def self.read_u24(io : IO) : Int32
      b0 = read_byte!(io).to_i
      b1 = read_byte!(io).to_i
      b2 = read_byte!(io).to_i
      b0 | (b1 << 8) | (b2 << 16)
    end

    private def self.read_u16(io : IO) : Int32
      b0 = read_byte!(io).to_i
      b1 = read_byte!(io).to_i
      b0 | (b1 << 8)
    end

    private def self.read_chunk(io : IO, env : Env, strings : Array(String)) : Chunk
      chunk = Chunk.new

      num_instructions = read_i32(io)
      num_instructions.times do
        op = Op.new(read_i32(io))
        a = read_i32(io)
        b = read_i32(io)
        c = read_i32(io)
        d = read_i32(io)
        has_pos = read_byte!(io) == 1_u8
        pos = if has_pos
                file = strings[read_u24(io)]
                line = read_u24(io)
                col = read_u16(io)
                SourcePos.new(file, line, col)
              end
        chunk.emit(op, a, b, c, d, pos)
      end

      num_consts = read_i32(io)
      num_consts.times { chunk.add_const_raw(read_datum(io, env, strings)) }

      num_protos = read_i32(io)
      num_protos.times { chunk.add_proto(read_chunk(io, env, strings)) }

      num_upvalues = read_i32(io)
      num_upvalues.times do
        from_parent_local = read_byte!(io) == 1_u8
        index = read_i32(io)
        name = strings[read_u24(io)]
        chunk.upvalues << UpvalDesc.new(from_parent_local, index, name)
      end

      chunk.param_count = read_i32(io)
      chunk.has_rest = read_byte!(io) == 1_u8
      chunk.num_registers = read_i32(io)
      chunk.name = strings[read_u24(io)]

      num_qq_templates = read_i32(io)
      num_qq_templates.times { chunk.add_qq_template(read_qq_template(io, env, strings)) }

      num_case_dispatch_tables = read_i32(io)
      num_case_dispatch_tables.times do
        idx = chunk.add_case_dispatch_table
        table = chunk.case_dispatch_tables[idx]
        read_case_dispatch_table_into(io, table, strings)
      end

      chunk
    end

    private def self.read_case_dispatch_table_into(io : IO, table : CaseDispatchTable, strings : Array(String)) : Nil
      table.default = read_i32(io)
      num_targets = read_i32(io)
      num_targets.times do
        tag = read_byte!(io)
        key = case tag
              when ChunkSerializer::CDK_INT
                CaseDispatchKey.for_int(read_i64(io))
              when ChunkSerializer::CDK_CHAR
                CaseDispatchKey.for_char(read_i64(io).to_i32.chr)
              when ChunkSerializer::CDK_SYM
                CaseDispatchKey.for_sym(strings[read_u24(io)])
              when ChunkSerializer::CDK_BOOL
                CaseDispatchKey.for_bool(read_i64(io) != 0)
              when ChunkSerializer::CDK_NIL
                CaseDispatchKey::NIL
              else
                raise FormatError.new("chunk_deserializer: unknown CaseDispatchKey tag #{tag}")
              end
        target = read_i32(io)
        table.targets[key] = target
      end
    end

    private def self.read_qq_template(io : IO, env : Env, strings : Array(String)) : QQTemplate
      tag = read_byte!(io)
      case tag
      when ChunkSerializer::QQ_CONST
        QQConst.new(read_datum(io, env, strings))
      when ChunkSerializer::QQ_HOLE
        # `.node` is a compile-time-only AST backreference that VM#build_qq
        # never reads (see its `case t; when QQHole` arm) — a placeholder
        # is fine here, there's no way (or need) to reconstruct the real one.
        QQHole.new(DUMMY_QQ_NODE)
      when ChunkSerializer::QQ_SPLICE
        QQSpliceItem.new(DUMMY_QQ_NODE)
      when ChunkSerializer::QQ_LIST
        count = read_i32(io)
        items = Array(QQTemplate).new(count) { read_qq_template(io, env, strings) }
        tail = read_qq_template(io, env, strings)
        QQList.new(items, tail)
      when ChunkSerializer::QQ_VECTOR
        count = read_i32(io)
        items = Array(QQTemplate).new(count) { read_qq_template(io, env, strings) }
        QQVector.new(items)
      else
        raise FormatError.new("chunk_deserializer: unknown QQTemplate tag #{tag}")
      end
    end

    # ameba:disable Metrics/CyclomaticComplexity
    private def self.read_datum(io : IO, env : Env, strings : Array(String)) : SchemeValue
      tag = read_byte!(io)
      case tag
      when ChunkSerializer::TAG_INT
        Creme.int_value(read_int_str(io))
      when ChunkSerializer::TAG_FLOAT
        SchemeFloat.new(io.read_bytes(Float64, IO::ByteFormat::LittleEndian))
      when ChunkSerializer::TAG_RATIONAL
        num = read_int_str(io)
        den = read_int_str(io)
        SchemeRational.make(num, den)
      when ChunkSerializer::TAG_COMPLEX
        real = read_datum(io, env, strings)
        imag = read_datum(io, env, strings)
        SchemeComplex.make(real.as(RealComponent), imag.as(RealComponent))
      when ChunkSerializer::TAG_SYM
        SchemeSym.of(strings[read_u24(io)])
      when ChunkSerializer::TAG_STR
        SchemeStr.new(strings[read_u24(io)])
      when ChunkSerializer::TAG_BOOL
        SchemeBool.of(read_byte!(io) == 1_u8)
      when ChunkSerializer::TAG_NIL
        NIL
      when ChunkSerializer::TAG_CHAR
        SchemeChar.new(read_i64(io).to_i32.chr)
      when ChunkSerializer::TAG_PAIR
        car = read_datum(io, env, strings)
        cdr = read_datum(io, env, strings)
        Cons.new(car, cdr)
      when ChunkSerializer::TAG_VECTOR
        count = read_i32(io)
        SchemeVector.new(Array(SchemeValue).new(count) { read_datum(io, env, strings) })
      when ChunkSerializer::TAG_BLOB
        count = read_i32(io)
        buf = Bytes.new(count)
        io.read_fully(buf)
        SchemeBlob.new(buf)
      when ChunkSerializer::TAG_BUILTIN
        name = strings[read_u24(io)]
        value = env.get?(name) || raise FormatError.new("chunk_deserializer: unknown builtin #{name.inspect}")
        value
      else
        raise FormatError.new("chunk_deserializer: unknown constant/datum tag #{tag}")
      end
    end
  end
end
