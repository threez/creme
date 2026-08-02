# ===========================================================================
# ChunkSerializer: dumps a compiled Chunk to the "SCB1" binary format that
# ChunkDeserializer reads back.
# ===========================================================================
#
# This exists for the self-hosting bootstrap effort, and is also the format
# the standalone C11 prototype VM in cvm/ reads directly (see cvm/README.md)
# — cvm/loader.c parses this exact wire format, so there is exactly one
# on-disk bytecode format across the whole project now, serializing Op's
# own enum ordinal directly and covering every opcode/value type Chunk can
# ever hold.
#
# `CVMEmitter` (cvm_emitter.cr) is one writer of this format, for `creme
# --emit-cvm`/cvm/. The self-hosted, Scheme-written bytecode compiler
# (modules/creme/compiler/compiler.sld, via modules/creme/bytecode.sld) is
# another — it builds the byte buffer directly with ordinary vector/
# bytevector operations, needing no Crystal-side serializer at all.
module Creme
  module ChunkSerializer
    MAGIC = "SCB1"
    # A single format-version byte, written immediately after MAGIC.
    # Bump this (in lockstep with modules/creme/bytecode.sld's own
    # writer, and cvm/loader.c's/chunk_deserializer.cr's own readers)
    # whenever the on-disk chunk layout itself changes in a way an
    # older reader couldn't safely parse -- so a stale precompiled
    # .cvmc (or a load-chunk-bytes blob built by a different creme/cvm
    # release) fails with a clean, actionable "re-emit this" error
    # instead of a reader silently misinterpreting bytes it wasn't
    # written for. See CHANGELOG.md/cvm/STABILITY.md for the
    # compatibility policy this exists to support.
    FORMAT_VERSION = 1_u8

    TAG_INT = 0_u8; TAG_FLOAT = 1_u8; TAG_RATIONAL = 2_u8; TAG_COMPLEX = 3_u8
    TAG_SYM     = 4_u8; TAG_STR = 5_u8; TAG_BOOL = 6_u8; TAG_NIL  = 7_u8
    TAG_CHAR = 8_u8; TAG_PAIR = 9_u8; TAG_VECTOR = 10_u8; TAG_BLOB    = 11_u8
    TAG_BUILTIN = 12_u8
    # Datum labels (R7RS #n=/#n#) -- only ever emitted for a Cons/
    # SchemeVector reached more than once while serializing ONE top-level
    # datum (a chunk const, or one QQ_CONST template's own literal
    # fragment -- see write_datum's own doc comment for the two-pass
    # scheme that decides this), so an ordinary, unshared literal
    # round-trips through byte-identical output to before these tags
    # existed. TAG_LABEL_DEF precedes that value's own ordinary tag+bytes
    # the FIRST time it's written (marking "this pointer may be
    # referenced again"); TAG_LABEL_REF stands alone (replacing a whole
    # datum) for every later encounter of the SAME pointer, whether via a
    # genuine cycle (a value reachable from its own contents) or a
    # separate, non-cyclic shared reference elsewhere in the same datum.
    TAG_LABEL_DEF = 13_u8; TAG_LABEL_REF = 14_u8

    CDK_INT = 0_u8; CDK_CHAR = 1_u8; CDK_SYM  = 2_u8
    CDK_BOOL = 3_u8; CDK_NIL = 4_u8

    QQ_CONST = 0_u8; QQ_HOLE = 1_u8; QQ_SPLICE = 2_u8
    QQ_LIST   = 3_u8; QQ_VECTOR = 4_u8

    def self.serialize(chunk : Chunk, required_families : Array(String) = [] of String) : Bytes
      io = IO::Memory.new
      io.write(MAGIC.to_slice)
      io.write_byte(FORMAT_VERSION)
      write_i32(io, required_families.size.to_i32)
      required_families.each { |name| write_string(io, name) }
      write_chunk(io, chunk)
      io.to_slice
    end

    private def self.write_i32(io : IO, v : Int32) : Nil
      io.write_bytes(v, IO::ByteFormat::LittleEndian)
    end

    private def self.write_i64(io : IO, v : Int64) : Nil
      io.write_bytes(v, IO::ByteFormat::LittleEndian)
    end

    private def self.write_string(io : IO, s : String) : Nil
      bytes = s.to_slice
      write_i32(io, bytes.size.to_i32)
      io.write(bytes)
    end

    # Source positions carry a filename resolved internally as an absolute
    # path (needed for correct `include`/relative-library resolution
    # regardless of the process's own working directory — see
    # Interpreter#push_load_dir/src/main.cr's emit_cvm), but that's a
    # correctness concern for FINDING files, not a reason to bake the
    # builder's own local filesystem layout into a persisted bytecode
    # artifact — position info is diagnostic-only (only ever read back by
    # --profile's report), so relativizing it here is free: no behavior
    # depends on this string once serialized. Falls back to the absolute
    # path only if relativizing itself somehow fails.
    private def self.relativize_path(path : String) : String
      Path.new(path).relative_to(Path.new(Dir.current)).to_s
    rescue
      path
    end

    private def self.write_chunk(io : IO, chunk : Chunk) : Nil
      write_i32(io, chunk.instructions.size.to_i32)
      chunk.instructions.each_with_index do |ins, i|
        write_i32(io, ins.op.to_i32)
        write_i32(io, ins.a)
        write_i32(io, ins.b)
        write_i32(io, ins.c)
        write_i32(io, ins.d)
        pos = chunk.positions[i]?
        if pos
          io.write_byte(1_u8)
          write_string(io, relativize_path(pos.file))
          write_i32(io, pos.line)
          write_i32(io, pos.col)
        else
          io.write_byte(0_u8)
        end
      end

      write_i32(io, chunk.consts.size.to_i32)
      chunk.consts.each { |v| write_datum(io, v) }

      write_i32(io, chunk.protos.size.to_i32)
      chunk.protos.each { |proto| write_chunk(io, proto) }

      write_i32(io, chunk.upvalues.size.to_i32)
      chunk.upvalues.each do |upval|
        io.write_byte(upval.from_parent_local? ? 1_u8 : 0_u8)
        write_i32(io, upval.index)
        write_string(io, upval.name)
      end

      write_i32(io, chunk.param_count)
      io.write_byte(chunk.has_rest? ? 1_u8 : 0_u8)
      write_i32(io, chunk.num_registers)
      write_string(io, chunk.name)

      write_i32(io, chunk.qq_templates.size.to_i32)
      chunk.qq_templates.each { |template| write_qq_template(io, template) }

      write_i32(io, chunk.case_dispatch_tables.size.to_i32)
      chunk.case_dispatch_tables.each { |table| write_case_dispatch_table(io, table) }
    end

    private def self.write_case_dispatch_table(io : IO, t : CaseDispatchTable) : Nil
      write_i32(io, t.default)
      write_i32(io, t.targets.size.to_i32)
      t.targets.each do |key, target|
        case key.tag
        when CaseDispatchKey::TAG_INT
          io.write_byte(CDK_INT)
          write_i64(io, key.ival)
        when CaseDispatchKey::TAG_CHAR
          io.write_byte(CDK_CHAR)
          write_i64(io, key.ival)
        when CaseDispatchKey::TAG_SYM
          io.write_byte(CDK_SYM)
          write_string(io, key.sval)
        when CaseDispatchKey::TAG_BOOL
          io.write_byte(CDK_BOOL)
          write_i64(io, key.ival)
        when CaseDispatchKey::TAG_NIL
          io.write_byte(CDK_NIL)
        else
          raise "chunk_serializer: unsupported CaseDispatchKey tag #{key.tag}"
        end
        write_i32(io, target)
      end
    end

    private def self.write_qq_template(io : IO, t : QQTemplate) : Nil
      case t
      when QQConst
        io.write_byte(QQ_CONST)
        write_datum(io, t.value)
      when QQHole
        io.write_byte(QQ_HOLE)
      when QQSpliceItem
        io.write_byte(QQ_SPLICE)
      when QQList
        io.write_byte(QQ_LIST)
        write_i32(io, t.items.size.to_i32)
        t.items.each { |item| write_qq_template(io, item) }
        write_qq_template(io, t.tail)
      when QQVector
        io.write_byte(QQ_VECTOR)
        write_i32(io, t.items.size.to_i32)
        t.items.each { |item| write_qq_template(io, item) }
      else
        raise "chunk_serializer: unsupported QQTemplate node #{t.class}"
      end
    end

    # Per-top-level-datum bookkeeping for the two-pass label-assignment
    # scheme below -- fresh for every write_datum call (R7RS: "a datum
    # label's scope is only the outermost datum it appears in"), NOT
    # shared across separate chunk consts/QQ_CONST literals.
    private struct DatumShareState
      getter counts : Hash(UInt64, Int32)
      getter labels = {} of UInt64 => Int32
      getter written = {} of UInt64 => Bool
      property next_label = 0

      def initialize(@counts)
      end
    end

    # First pass: counts how many times each distinct Cons/SchemeVector
    # pointer (keyed by object_id -- both are `class`es, so this is
    # genuine reference identity, not structural equality) is reached
    # while walking `v`. Re-entering a pointer already in `counts` --
    # whether because it's a genuine cycle still mid-traversal, or a
    # separate later reference to already-fully-walked shared
    # substructure -- stops further descent there (same reasoning cvm's
    # own cvm_equal/write_value_shared use for the identical problem):
    # this is what makes the pass terminate on a circular datum instead
    # of recursing forever. Every scalar tag (ints, symbols, strings, …)
    # is untouched -- only pairs/vectors can be shared/cyclic here.
    private def self.count_datum_visits(v : SchemeValue, counts : Hash(UInt64, Int32)) : Nil
      return unless v.is_a?(Cons) || v.is_a?(SchemeVector)
      id = v.object_id
      if counts.has_key?(id)
        counts[id] += 1
        return
      end
      counts[id] = 1
      case v
      when Cons
        count_datum_visits(v.car, counts)
        count_datum_visits(v.cdr, counts)
      when SchemeVector
        v.value.each { |item| count_datum_visits(item, counts) }
      end
    end

    # Recursively serializes any SchemeValue that can appear as a chunk
    # constant, a quasiquote literal fragment, or a nested pair/vector
    # datum. Runs count_datum_visits once up front, then delegates to
    # write_datum_rec (below), which threads that same state through
    # every recursive call so a pointer visited >=2 times gets a
    # TAG_LABEL_DEF the first time and a bare TAG_LABEL_REF (no
    # re-serialized contents at all) every time after -- see
    # TAG_LABEL_DEF/TAG_LABEL_REF's own doc comment above for the wire
    # shape, and cvm/loader.c's read_datum for the matching reader side.
    private def self.write_datum(io : IO, v : SchemeValue) : Nil
      counts = {} of UInt64 => Int32
      count_datum_visits(v, counts)
      write_datum_rec(io, v, DatumShareState.new(counts))
    end

    # ameba:disable Metrics/CyclomaticComplexity
    private def self.write_datum_rec(io : IO, v : SchemeValue, state : DatumShareState) : Nil
      if (v.is_a?(Cons) || v.is_a?(SchemeVector)) && state.counts[v.object_id] >= 2
        id = v.object_id
        if state.written[id]?
          io.write_byte(TAG_LABEL_REF)
          write_i32(io, state.labels[id])
          return
        end
        label = state.labels[id]? || (state.labels[id] = state.next_label.tap { state.next_label += 1 })
        io.write_byte(TAG_LABEL_DEF)
        write_i32(io, label)
        state.written[id] = true
        # Falls through below to write this datum's own ordinary
        # tag+contents -- the label prefix above is additive, not a
        # replacement for the normal encoding.
      end
      case v
      when SchemeInt
        io.write_byte(TAG_INT)
        write_i64(io, v.value)
      when SchemeFloat
        io.write_byte(TAG_FLOAT)
        io.write_bytes(v.value, IO::ByteFormat::LittleEndian)
      when SchemeRational
        io.write_byte(TAG_RATIONAL)
        write_i64(io, v.numerator)
        write_i64(io, v.denominator)
      when SchemeComplex
        io.write_byte(TAG_COMPLEX)
        write_datum_rec(io, v.real, state)
        write_datum_rec(io, v.imag, state)
      when SchemeSym
        io.write_byte(TAG_SYM)
        write_string(io, v.name)
      when SchemeStr
        io.write_byte(TAG_STR)
        write_string(io, v.value)
      when SchemeBool
        io.write_byte(TAG_BOOL)
        io.write_byte(v.value? ? 1_u8 : 0_u8)
      when SchemeNil
        io.write_byte(TAG_NIL)
      when SchemeChar
        io.write_byte(TAG_CHAR)
        write_i64(io, v.value.ord.to_i64)
      when Cons
        io.write_byte(TAG_PAIR)
        write_datum_rec(io, v.car, state)
        write_datum_rec(io, v.cdr, state)
      when SchemeVector
        io.write_byte(TAG_VECTOR)
        write_i32(io, v.value.size.to_i32)
        v.value.each { |item| write_datum_rec(io, item, state) }
      when SchemeBlob
        io.write_byte(TAG_BLOB)
        write_i32(io, v.value.size.to_i32)
        io.write(v.value)
      when Builtin
        io.write_byte(TAG_BUILTIN)
        write_string(io, v.name)
      else
        raise "chunk_serializer: unsupported constant/datum type #{v.class}"
      end
    end
  end
end
