# ===========================================================================
# ChunkDeserializer: the inverse of ChunkSerializer's "ICE1" format.
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
      raise FormatError.new("chunk_deserializer: bad magic #{magic.inspect}, expected #{ChunkSerializer::MAGIC.inspect}") unless magic == ChunkSerializer::MAGIC
      version = read_byte!(io)
      unless version == ChunkSerializer::FORMAT_VERSION
        raise FormatError.new("chunk_deserializer: format version #{version} (expected #{ChunkSerializer::FORMAT_VERSION}) -- re-emit this chunk with the current creme/icecreme")
      end
      read_required_families(io) # not yet consumed by any caller; just skip past it
      read_chunk(io, env)
    end

    # Reads (and discards) the "required families" metadata section that sits
    # between the magic and the chunk body — see ChunkSerializer.serialize.
    # Nothing reads this yet, but it must be consumed here so the chunk body
    # that immediately follows it is read from the right offset.
    private def self.read_required_families(io : IO) : Array(String)
      count = read_i32(io)
      Array(String).new(count) { read_string(io) }
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

    private def self.read_string(io : IO) : String
      len = read_i32(io)
      buf = Bytes.new(len)
      io.read_fully(buf)
      String.new(buf)
    end

    private def self.read_chunk(io : IO, env : Env) : Chunk
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
                file = read_string(io)
                line = read_i32(io)
                col = read_i32(io)
                SourcePos.new(file, line, col)
              end
        chunk.emit(op, a, b, c, d, pos)
      end

      num_consts = read_i32(io)
      num_consts.times { chunk.add_const_raw(read_datum(io, env)) }

      num_protos = read_i32(io)
      num_protos.times { chunk.add_proto(read_chunk(io, env)) }

      num_upvalues = read_i32(io)
      num_upvalues.times do
        from_parent_local = read_byte!(io) == 1_u8
        index = read_i32(io)
        name = read_string(io)
        chunk.upvalues << UpvalDesc.new(from_parent_local, index, name)
      end

      chunk.param_count = read_i32(io)
      chunk.has_rest = read_byte!(io) == 1_u8
      chunk.num_registers = read_i32(io)
      chunk.name = read_string(io)

      num_qq_templates = read_i32(io)
      num_qq_templates.times { chunk.add_qq_template(read_qq_template(io, env)) }

      num_case_dispatch_tables = read_i32(io)
      num_case_dispatch_tables.times do
        idx = chunk.add_case_dispatch_table
        table = chunk.case_dispatch_tables[idx]
        read_case_dispatch_table_into(io, table)
      end

      chunk
    end

    private def self.read_case_dispatch_table_into(io : IO, table : CaseDispatchTable) : Nil
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
                CaseDispatchKey.for_sym(read_string(io))
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

    private def self.read_qq_template(io : IO, env : Env) : QQTemplate
      tag = read_byte!(io)
      case tag
      when ChunkSerializer::QQ_CONST
        QQConst.new(read_datum(io, env))
      when ChunkSerializer::QQ_HOLE
        # `.node` is a compile-time-only AST backreference that VM#build_qq
        # never reads (see its `case t; when QQHole` arm) — a placeholder
        # is fine here, there's no way (or need) to reconstruct the real one.
        QQHole.new(DUMMY_QQ_NODE)
      when ChunkSerializer::QQ_SPLICE
        QQSpliceItem.new(DUMMY_QQ_NODE)
      when ChunkSerializer::QQ_LIST
        count = read_i32(io)
        items = Array(QQTemplate).new(count) { read_qq_template(io, env) }
        tail = read_qq_template(io, env)
        QQList.new(items, tail)
      when ChunkSerializer::QQ_VECTOR
        count = read_i32(io)
        items = Array(QQTemplate).new(count) { read_qq_template(io, env) }
        QQVector.new(items)
      else
        raise FormatError.new("chunk_deserializer: unknown QQTemplate tag #{tag}")
      end
    end

    # ameba:disable Metrics/CyclomaticComplexity
    private def self.read_datum(io : IO, env : Env) : SchemeValue
      tag = read_byte!(io)
      case tag
      when ChunkSerializer::TAG_INT
        SchemeInt.new(read_i64(io))
      when ChunkSerializer::TAG_FLOAT
        SchemeFloat.new(io.read_bytes(Float64, IO::ByteFormat::LittleEndian))
      when ChunkSerializer::TAG_RATIONAL
        num = read_i64(io)
        den = read_i64(io)
        SchemeRational.make(num, den)
      when ChunkSerializer::TAG_COMPLEX
        real = read_datum(io, env)
        imag = read_datum(io, env)
        SchemeComplex.make(real.as(RealComponent), imag.as(RealComponent))
      when ChunkSerializer::TAG_SYM
        SchemeSym.of(read_string(io))
      when ChunkSerializer::TAG_STR
        SchemeStr.new(read_string(io))
      when ChunkSerializer::TAG_BOOL
        SchemeBool.of(read_byte!(io) == 1_u8)
      when ChunkSerializer::TAG_NIL
        NIL
      when ChunkSerializer::TAG_CHAR
        SchemeChar.new(read_i64(io).to_i32.chr)
      when ChunkSerializer::TAG_PAIR
        car = read_datum(io, env)
        cdr = read_datum(io, env)
        Cons.new(car, cdr)
      when ChunkSerializer::TAG_VECTOR
        count = read_i32(io)
        SchemeVector.new(Array(SchemeValue).new(count) { read_datum(io, env) })
      when ChunkSerializer::TAG_BLOB
        count = read_i32(io)
        buf = Bytes.new(count)
        io.read_fully(buf)
        SchemeBlob.new(buf)
      when ChunkSerializer::TAG_BUILTIN
        name = read_string(io)
        value = env.get?(name) || raise FormatError.new("chunk_deserializer: unknown builtin #{name.inspect}")
        value
      else
        raise FormatError.new("chunk_deserializer: unknown constant/datum tag #{tag}")
      end
    end
  end
end
