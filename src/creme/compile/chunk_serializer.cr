# ===========================================================================
# ChunkSerializer: dumps a compiled Chunk to the "ICE" binary format that
# ChunkDeserializer reads back.
# ===========================================================================
#
# This exists for the self-hosting bootstrap effort, and is also the format
# the standalone C11 prototype VM in icecreme/ reads directly (see icecreme/README.md)
# — icecreme/loader.c parses this exact wire format, so there is exactly one
# on-disk bytecode format across the whole project now, serializing Op's
# own enum ordinal directly and covering every opcode/value type Chunk can
# ever hold.
#
# `IcecremeEmitter` (icecreme_emitter.cr) is one writer of this format, for `creme
# --emit-icecreme`/icecreme/. The self-hosted, Scheme-written bytecode compiler
# (modules/creme/compiler/compiler.sld, via modules/creme/bytecode.sld) is
# another — it builds the byte buffer directly with ordinary vector/
# bytevector operations, needing no Crystal-side serializer at all.
module Creme
  module ChunkSerializer
    # The on-disk format version. It is NOT stored as a separate byte:
    # the 4-byte magic IS "ICE" + one ASCII version digit ('0' + version),
    # e.g. version 1 = "ICE1", and a reader learns the version straight from
    # the 4th magic byte (byte3 - '0'). Bump this (in
    # lockstep with modules/creme/bytecode.sld's own writer, and
    # icecreme/loader.c's/chunk_deserializer.cr's own readers) whenever the
    # on-disk chunk layout itself changes in a way an older reader couldn't
    # safely parse -- so a stale precompiled .ice (or a load-chunk-bytes
    # blob built by a different creme/icecreme release) fails with a clean,
    # actionable "re-emit this" error instead of a reader silently
    # misinterpreting bytes it wasn't written for. See
    # CHANGELOG.md/icecreme/STABILITY.md for the compatibility policy this
    # exists to support.
    FORMAT_VERSION = 1
    MAGIC_PREFIX   = "ICE"
    # 4-byte magic string: "ICE" + the ASCII digit for FORMAT_VERSION.
    MAGIC = "#{MAGIC_PREFIX}#{('0'.ord + FORMAT_VERSION).chr}"

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

    # Interns every distinct string/symbol the chunk tree references into a
    # single global pool written once near the file header; every inline
    # string then becomes a small u24 index into it (see this file's own
    # header and the plan). `intern` assigns a fresh index on first sight
    # (mirroring DatumShareState's assign-on-first-sight idiom); `id` looks
    # up an already-interned string during the write pass (a KeyError here
    # would mean the collect and write walks disagree on which strings the
    # chunk references -- a serializer bug, not bad input).
    private class StringInterner
      getter strings = [] of String
      @index = {} of String => Int32

      def intern(s : String) : Int32
        idx = @index[s]?
        return idx if idx
        i = @strings.size
        @strings << s
        @index[s] = i
        i
      end

      def id(s : String) : Int32
        @index[s]
      end
    end

    def self.serialize(chunk : Chunk, required_families : Array(String) = [] of String) : Bytes
      # Pass 1: collect every string/symbol into the pool, in first-seen order.
      pool = StringInterner.new
      required_families.each { |name| pool.intern(name) }
      collect_chunk_strings(chunk, pool)
      max_pool_size = 0xFF_FFFF
      if pool.strings.size > max_pool_size
        raise "chunk_serializer: string pool too large (#{pool.strings.size} > #{max_pool_size}) for a u24 index"
      end

      # Pass 2: write the pool, then the chunk with u24 pool indices in place
      # of every inline string, into a BODY buffer -- then the file is the
      # plaintext MAGIC ("ICE1") followed by a single zstd frame of that body.
      # The body compresses ~6x (big interned string pool + repetitive packed
      # opcodes); zstd is a required dependency of every backend now (loader.c,
      # bytecode.sld's reader/writer, and here all move in lockstep -- see
      # loader.c's own format-version comment). Level 19 is deterministic for a
      # given libzstd, so the self-hosting fixpoint still holds.
      body = IO::Memory.new
      write_i32(body, pool.strings.size.to_i32)
      pool.strings.each { |str| write_pool_string(body, str) }
      write_i32(body, required_families.size.to_i32)
      required_families.each { |name| write_u24(body, pool.id(name)) }
      write_chunk(body, chunk, pool)
      out = IO::Memory.new
      out.write(MAGIC.to_slice)
      out.write(Creme::Builtins::ZstdLibrary.compress_bytes(body.to_slice, 19, "chunk_serializer"))
      out.to_slice
    end

    private def self.write_i32(io : IO, v : Int32) : Nil
      io.write_bytes(v, IO::ByteFormat::LittleEndian)
    end

    private def self.write_i64(io : IO, v : Int64) : Nil
      io.write_bytes(v, IO::ByteFormat::LittleEndian)
    end

    # Little-endian unsigned 24-/16-bit writes for pool indices and the
    # narrow position fields (file-index/line as u24, col as u16).
    private def self.write_u24(io : IO, v : Int32) : Nil
      io.write_byte((v & 0xFF).to_u8)
      io.write_byte(((v >> 8) & 0xFF).to_u8)
      io.write_byte(((v >> 16) & 0xFF).to_u8)
    end

    private def self.write_u16(io : IO, v : Int32) : Nil
      io.write_byte((v & 0xFF).to_u8)
      io.write_byte(((v >> 8) & 0xFF).to_u8)
    end

    private def self.clamp_u24(v : Int32) : Int32
      v < 0 ? 0 : (v > 0xFF_FFFF ? 0xFF_FFFF : v)
    end

    private def self.clamp_u16(v : Int32) : Int32
      v < 0 ? 0 : (v > 0xFFFF ? 0xFFFF : v)
    end

    # A pool entry itself: raw length-prefixed bytes (written once).
    private def self.write_pool_string(io : IO, s : String) : Nil
      bytes = s.to_slice
      write_i32(io, bytes.size.to_i32)
      io.write(bytes)
    end

    # Source positions carry a filename resolved internally as an absolute
    # path (needed for correct `include`/relative-library resolution
    # regardless of the process's own working directory — see
    # Interpreter#push_load_dir/src/main.cr's emit_icecreme), but that's a
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

    # Pass 1 of serialization: walk the whole chunk tree exactly as
    # write_chunk does, interning every string/symbol it will later write as
    # a pool index. Kept structurally parallel to write_chunk below so the
    # two never disagree about which strings the chunk references.
    private def self.collect_chunk_strings(chunk : Chunk, pool : StringInterner) : Nil
      chunk.instructions.each_with_index do |_, i|
        pos = chunk.positions[i]?
        pool.intern(relativize_path(pos.file)) if pos
      end
      chunk.consts.each { |v| collect_datum_strings(v, pool, Set(UInt64).new) }
      chunk.protos.each { |proto| collect_chunk_strings(proto, pool) }
      chunk.upvalues.each { |upval| pool.intern(upval.name) }
      pool.intern(chunk.name)
      chunk.qq_templates.each { |template| collect_qq_template_strings(template, pool) }
      chunk.case_dispatch_tables.each do |table|
        table.targets.each_key do |key|
          pool.intern(key.sval) if key.tag == CaseDispatchKey::TAG_SYM
        end
      end
    end

    # Cycle-guarded (via a per-top-level-datum object_id set) walk collecting
    # the strings inside a const datum -- symbols, strings, and builtin
    # names, recursing through pairs/vectors/complex just like write_datum_rec.
    private def self.collect_datum_strings(v : SchemeValue, pool : StringInterner, seen : Set(UInt64)) : Nil
      case v
      when SchemeSym then pool.intern(v.name)
      when SchemeStr then pool.intern(v.value)
      when Builtin   then pool.intern(v.name)
      when SchemeComplex
        collect_datum_strings(v.real, pool, seen)
        collect_datum_strings(v.imag, pool, seen)
      when Cons
        return unless seen.add?(v.object_id)
        collect_datum_strings(v.car, pool, seen)
        collect_datum_strings(v.cdr, pool, seen)
      when SchemeVector
        return unless seen.add?(v.object_id)
        v.value.each { |item| collect_datum_strings(item, pool, seen) }
      end
    end

    private def self.collect_qq_template_strings(t : QQTemplate, pool : StringInterner) : Nil
      case t
      when QQConst
        collect_datum_strings(t.value, pool, Set(UInt64).new)
      when QQList
        t.items.each { |item| collect_qq_template_strings(item, pool) }
        collect_qq_template_strings(t.tail, pool)
      when QQVector
        t.items.each { |item| collect_qq_template_strings(item, pool) }
      end
    end

    private def self.write_chunk(io : IO, chunk : Chunk, pool : StringInterner) : Nil
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
          write_u24(io, pool.id(relativize_path(pos.file)))
          write_u24(io, clamp_u24(pos.line))
          write_u16(io, clamp_u16(pos.col))
        else
          io.write_byte(0_u8)
        end
      end

      write_i32(io, chunk.consts.size.to_i32)
      chunk.consts.each { |v| write_datum(io, v, pool) }

      write_i32(io, chunk.protos.size.to_i32)
      chunk.protos.each { |proto| write_chunk(io, proto, pool) }

      write_i32(io, chunk.upvalues.size.to_i32)
      chunk.upvalues.each do |upval|
        io.write_byte(upval.from_parent_local? ? 1_u8 : 0_u8)
        write_i32(io, upval.index)
        write_u24(io, pool.id(upval.name))
      end

      write_i32(io, chunk.param_count)
      io.write_byte(chunk.has_rest? ? 1_u8 : 0_u8)
      write_i32(io, chunk.num_registers)
      write_u24(io, pool.id(chunk.name))

      write_i32(io, chunk.qq_templates.size.to_i32)
      chunk.qq_templates.each { |template| write_qq_template(io, template, pool) }

      write_i32(io, chunk.case_dispatch_tables.size.to_i32)
      chunk.case_dispatch_tables.each { |table| write_case_dispatch_table(io, table, pool) }
    end

    private def self.write_case_dispatch_table(io : IO, t : CaseDispatchTable, pool : StringInterner) : Nil
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
          write_u24(io, pool.id(key.sval))
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

    private def self.write_qq_template(io : IO, t : QQTemplate, pool : StringInterner) : Nil
      case t
      when QQConst
        io.write_byte(QQ_CONST)
        write_datum(io, t.value, pool)
      when QQHole
        io.write_byte(QQ_HOLE)
      when QQSpliceItem
        io.write_byte(QQ_SPLICE)
      when QQList
        io.write_byte(QQ_LIST)
        write_i32(io, t.items.size.to_i32)
        t.items.each { |item| write_qq_template(io, item, pool) }
        write_qq_template(io, t.tail, pool)
      when QQVector
        io.write_byte(QQ_VECTOR)
        write_i32(io, t.items.size.to_i32)
        t.items.each { |item| write_qq_template(io, item, pool) }
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
    # substructure -- stops further descent there (same reasoning icecreme's
    # own creme_equal/write_value_shared use for the identical problem):
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
    # shape, and icecreme/loader.c's read_datum for the matching reader side.
    private def self.write_datum(io : IO, v : SchemeValue, pool : StringInterner) : Nil
      counts = {} of UInt64 => Int32
      count_datum_visits(v, counts)
      write_datum_rec(io, v, DatumShareState.new(counts), pool)
    end

    # ameba:disable Metrics/CyclomaticComplexity
    private def self.write_datum_rec(io : IO, v : SchemeValue, state : DatumShareState, pool : StringInterner) : Nil
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
        write_datum_rec(io, v.real, state, pool)
        write_datum_rec(io, v.imag, state, pool)
      when SchemeSym
        io.write_byte(TAG_SYM)
        write_u24(io, pool.id(v.name))
      when SchemeStr
        io.write_byte(TAG_STR)
        write_u24(io, pool.id(v.value))
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
        write_datum_rec(io, v.car, state, pool)
        write_datum_rec(io, v.cdr, state, pool)
      when SchemeVector
        io.write_byte(TAG_VECTOR)
        write_i32(io, v.value.size.to_i32)
        v.value.each { |item| write_datum_rec(io, item, state, pool) }
      when SchemeBlob
        io.write_byte(TAG_BLOB)
        write_i32(io, v.value.size.to_i32)
        io.write(v.value)
      when Builtin
        io.write_byte(TAG_BUILTIN)
        write_u24(io, pool.id(v.name))
      else
        raise "chunk_serializer: unsupported constant/datum type #{v.class}"
      end
    end
  end
end
