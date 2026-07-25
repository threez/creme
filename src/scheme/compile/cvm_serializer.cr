# ===========================================================================
# CVMSerializer: dumps compiled Chunks to the binary format the standalone
# C11 prototype VM (cvm/) loads and executes.
# ===========================================================================
#
# Scope note: `cvm/` is a small prototype scoped to exactly what
# `bench/creme.scm` (workloads.scm + workloads-demo.scm) compiles down to —
# see cvm/README.md. This serializer only knows how to encode the opcode/
# constant-type subset that program actually uses (OP_IDS below); it raises
# immediately on anything else so a future change to the benchmarked code (or
# feeding it some other script) fails loudly at emit time instead of
# producing a file the C loader would misinterpret.
#
# The format is deliberately simple/uncompressed (no varints, no string
# interning beyond what Chunk#add_const already does): a fixed, explicit
# little-endian binary layout mirroring Chunk's own fields one-for-one, so
# the C loader (cvm/loader.c) can read it with a handful of straight-line
# fread calls. Op names are written as fixed small integers from OP_IDS
# (a table private to this file, NOT Op's own enum ordinals) so the format
# stays stable even if Scheme::Op gets reordered/extended later — the C
# loader keeps its own copy of the same table.
module Scheme
  module CVMSerializer
    # Bumped from "CVM1" to "CVM2" when per-instruction source lines (used by
    # cvm's --profile report) were added to the header/instruction layout —
    # old CVM1 files are no longer readable by cvm/loader.c, re-emit them.
    MAGIC = "CVM2"

    # Op name => stable on-disk id. Extend both this and cvm/opcodes.h in
    # lockstep if the benchmarked program ever needs a currently-unsupported
    # op.
    OP_IDS = {
      "LoadK" => 0, "LoadNil" => 1, "LoadTrue" => 2, "LoadFalse" => 3,
      "Move" => 4, "GetUpval" => 5, "GetGlobal" => 6, "DefGlobal" => 7,
      "Add" => 8, "Sub" => 9, "Cons" => 10, "IsNull" => 11, "NumEq" => 12,
      "AddImm" => 13, "SubImm" => 14, "MulImm" => 15,
      "TestLtImm" => 16, "TestEqImm" => 17, "TestLt" => 18,
      "TestLtUp" => 19, "TestEqUp" => 20, "TestFalse" => 21, "Jmp" => 22,
      "Cxr" => 23, "Abs" => 24, "Closure" => 25, "HelperForm" => 26,
      "Call" => 27, "TailCall" => 28, "CallGlobal" => 29, "TailCallGlobal" => 30,
      "CallLocal" => 31, "TailCallLocal" => 32, "CallUpval" => 33, "TailCallUpval" => 34,
      "Return" => 35, "AddReturn" => 36, "VecRefUp" => 37, "VecSetUp" => 38,
      "Not" => 39, "Quasiquote" => 40,
      "Mul" => 41, "NumLt" => 42, "NumGe" => 43, "NumLtImm" => 44,
      "NumGtImm" => 45, "NumEqImm" => 46, "AddUp" => 47, "NumGeUp" => 48,
      "NumLeUp" => 49, "IsPair" => 50, "IsEq" => 51, "SetUpval" => 52,
      "VecRefImm" => 53, "VecSetImm" => 54, "StrRefImm" => 55, "StrRefUp" => 56,
      "TestGe" => 57, "TestGtImm" => 58, "TestIsEq" => 59, "CaseDispatch" => 60,
      "NumLe" => 61, "NumGt" => 62, "NumLeImm" => 63, "NumGeImm" => 64,
      "SubUp" => 65, "MulUp" => 66, "NumLtUp" => 67, "NumGtUp" => 68, "NumEqUp" => 69,
      "IsEqImm" => 70, "IsEqUp" => 71, "TestLe" => 72, "TestGt" => 73,
      "TestLeImm" => 74, "TestGeImm" => 75, "TestIsEqImm" => 76,
      "VecRef" => 77, "VecLen" => 78, "VecSet" => 79, "VecLenUp" => 80,
      "CaseMatch" => 81, "SubReturn" => 82, "MulReturn" => 83,
    }

    TAG_INT = 0_u8; TAG_FLOAT = 1_u8; TAG_SYM = 2_u8
    TAG_STR = 3_u8; TAG_BOOL = 4_u8; TAG_NIL  = 5_u8
    TAG_PAIR = 6_u8; TAG_VECTOR = 7_u8; TAG_CHAR = 8_u8

    # Op::CaseDispatch key tags — mirrors chunk.cr's CaseDispatchKey::TAG_*.
    CDK_INT = 0_u8; CDK_CHAR = 1_u8; CDK_SYM  = 2_u8
    CDK_BOOL = 3_u8; CDK_NIL = 4_u8

    # QQTemplate node tags (see ast.cr's QQConst/QQHole/QQSpliceItem/QQList/
    # QQVector) — a chunk's own `qq_templates` table (Chunk#add_qq_template)
    # is otherwise Crystal-VM-only (only `VM#build_qq` reads it); this format
    # mirrors that same tree shape so cvm/vm.c's own build_qq can walk it
    # identically. QQHole/QQSpliceItem carry no payload of their own — the
    # hole's value was already compiled into its own contiguous register by
    # compile_qq_holes, and both the Crystal VM's build_qq and cvm's mirror
    # pull it out purely by traversal order (see build_qq's own comment in
    # vm.cr), so nothing needs to be written beyond the tag byte itself.
    QQ_CONST = 0_u8; QQ_HOLE = 1_u8; QQ_SPLICE = 2_u8
    QQ_LIST   = 3_u8; QQ_VECTOR = 4_u8

    # Compiles each of `forms` into its own top-level Chunk (mirroring
    # `BytecodeCompiler.run_program`'s per-form analyze/compile step) and
    # writes them all to `path`. Deliberately does NOT run each compiled
    # chunk through the Crystal VM between forms (unlike run_program/
    # dump_bytecode) — safe here specifically because bench/creme.scm's own
    # forms never rely on a prior form's runtime side effect (a local
    # defmacro/define-syntax/reader extension, or a real library import) to
    # compile correctly; every cross-form reference is an ordinary global
    # name (GetGlobal/CallGlobal), resolved dynamically at RUN time in the C
    # VM regardless of Crystal-side execution order.
    #
    # A target script importing file-based `.sld` libraries (e.g.
    # `(creme dao)`) is NOT that simple, though: `(import ...)` analyzes down
    # to a inert HelperFormNode (analyzer.cr) — the REAL loading (parsing the
    # library's own source, running its body for real against its own Env,
    # registering any top-level `defmacro`/`define-syntax`) only happens when
    # `Op::HelperForm` actually EXECUTES in a real VM (`eval_import`, called
    # from vm.cr's HelperForm dispatch) — so merely analyzing an `(import
    # ...)` form (as the loop below does for every other form) never
    # populates `interp.libraries`, and never registers macros a later form
    # in the same file needs to expand correctly (e.g. `(define-dao todo
    # conn ...)` right after `(import (creme dao) ...)`). So each `(import
    # ...)` form found here is ALSO run for real, via `interp.eval_import`,
    # the moment it's encountered — exactly the one runtime side effect this
    # method needs (matching run_program's own incremental analyze-compile-
    # RUN-one-form-at-a-time model, but scoped to just this one special form
    # rather than running every compiled chunk). This does not run any of
    # the target script's OTHER side-effecting forms for real (no
    # `sql-open`/`mux-listen!`/etc.) — only a library's own body, which is
    # the same real execution an ordinary `./bin/creme <file>` run would do
    # anyway, just triggered a little earlier (at analyze time here, instead
    # of when the compiled HelperForm op would otherwise run).
    #
    # Once every `(import ...)` in `forms` has been analyzed (and thus really
    # run), `interp.libraries` holds every transitively-loaded library, in
    # load order. Every file-based one gets its own top-level body forms
    # re-read/re-analyzed/re-compiled here too (a SECOND compile pass purely
    # for cvm's benefit — see `Interpreter#library_body_forms_for_cvm`), and
    # its chunks are written FIRST, so the C loader defines each library's
    # globals before the target script's own top-level forms run. A
    # Crystal-native library (e.g. `(creme mux)`, no `.sld` file of its own)
    # has nothing to compile — `library_body_forms_for_cvm` returns nil for
    # those, and cvm implements their Scheme-visible surface as hand-written
    # native builtins instead (see cvm/mux.c et al.).
    def self.emit(interp : Interpreter, forms : Array(SchemeValue), env : Env, path : String, source_file : String) : Nil
      target_env = env
      app_chunks = forms.map do |form|
        interp.eval_import(form, target_env) if form.is_a?(Cons) && (head = form.car).is_a?(SchemeSym) && head.name == "import"
        node = interp.analyze(form, target_env)
        BytecodeCompiler.compile_program([node])
      end

      library_chunks = [] of Chunk
      interp.libraries.each do |name, library|
        body_forms = interp.library_body_forms_for_cvm(name)
        next unless body_forms
        body_forms.each do |form|
          node = interp.analyze(form, library.env)
          library_chunks << BytecodeCompiler.compile_program([node])
        end
      end

      chunks = library_chunks + app_chunks
      File.open(path, "wb") do |io|
        io.write(MAGIC.to_slice)
        write_string(io, source_file)
        io.write_bytes(chunks.size.to_i32, IO::ByteFormat::LittleEndian)
        chunks.each { |chunk| write_chunk(io, chunk) }
      end
    end

    private def self.write_i32(io : IO, v : Int32) : Nil
      io.write_bytes(v, IO::ByteFormat::LittleEndian)
    end

    private def self.write_string(io : IO, s : String) : Nil
      bytes = s.to_slice
      write_i32(io, bytes.size.to_i32)
      io.write(bytes)
    end

    private def self.write_chunk(io : IO, chunk : Chunk) : Nil
      write_i32(io, chunk.instructions.size.to_i32)
      chunk.instructions.each_with_index do |ins, i|
        op_id = OP_IDS[ins.op.to_s]? || raise "cvm: unsupported opcode #{ins.op} in chunk #{chunk.name.inspect} — extend CVMSerializer::OP_IDS + cvm/opcodes.h"
        write_i32(io, op_id)
        write_i32(io, ins.a)
        write_i32(io, ins.b)
        write_i32(io, ins.c)
        write_i32(io, ins.d)
        # 0 = no source position (most non-call instructions) — used only by
        # cvm's --profile report to symbolize hot instructions as file:line.
        write_i32(io, chunk.positions[i]?.try(&.line) || 0)
      end

      write_i32(io, chunk.consts.size.to_i32)
      chunk.consts.each { |v| write_const(io, v, chunk) }

      write_i32(io, chunk.protos.size.to_i32)
      chunk.protos.each { |proto| write_chunk(io, proto) }

      write_i32(io, chunk.upvalues.size.to_i32)
      chunk.upvalues.each do |u|
        io.write_byte(u.from_parent_local ? 1_u8 : 0_u8)
        write_i32(io, u.index)
      end

      write_i32(io, chunk.param_count)
      io.write_byte(chunk.has_rest? ? 1_u8 : 0_u8)
      write_i32(io, chunk.num_registers)
      write_string(io, chunk.name)

      write_i32(io, chunk.qq_templates.size.to_i32)
      chunk.qq_templates.each { |t| write_qq_template(io, t) }

      write_i32(io, chunk.case_dispatch_tables.size.to_i32)
      chunk.case_dispatch_tables.each { |t| write_case_dispatch_table(io, t) }
    end

    private def self.write_case_dispatch_table(io : IO, t : CaseDispatchTable) : Nil
      write_i32(io, t.default)
      write_i32(io, t.targets.size.to_i32)
      t.targets.each do |key, target|
        case key.tag
        when CaseDispatchKey::TAG_INT
          io.write_byte(CDK_INT)
          io.write_bytes(key.ival, IO::ByteFormat::LittleEndian)
        when CaseDispatchKey::TAG_CHAR
          io.write_byte(CDK_CHAR)
          io.write_bytes(key.ival, IO::ByteFormat::LittleEndian)
        when CaseDispatchKey::TAG_SYM
          io.write_byte(CDK_SYM)
          write_string(io, key.sval)
        when CaseDispatchKey::TAG_BOOL
          io.write_byte(CDK_BOOL)
          io.write_bytes(key.ival, IO::ByteFormat::LittleEndian)
        when CaseDispatchKey::TAG_NIL
          io.write_byte(CDK_NIL)
        else
          raise "cvm: unsupported CaseDispatchKey tag #{key.tag}"
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
        raise "cvm: unsupported QQTemplate node #{t.class}"
      end
    end

    # A general recursive SchemeValue serializer for QQConst's literal-
    # fragment payload — unlike write_const's Cons/Builtin cases (which only
    # ever stash a placeholder for a value the C VM never actually inspects),
    # a quasiquote template's literal fragments are real data the loader must
    # reconstruct verbatim (e.g. the `(b c)` in `` `(a (b c) ,d) ``).
    private def self.write_datum(io : IO, v : SchemeValue) : Nil
      case v
      when SchemeInt
        io.write_byte(TAG_INT)
        io.write_bytes(v.value, IO::ByteFormat::LittleEndian)
      when SchemeFloat
        io.write_byte(TAG_FLOAT)
        io.write_bytes(v.value, IO::ByteFormat::LittleEndian)
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
        io.write_bytes(v.value.ord.to_i64, IO::ByteFormat::LittleEndian)
      when Cons
        io.write_byte(TAG_PAIR)
        write_datum(io, v.car)
        write_datum(io, v.cdr)
      when SchemeVector
        io.write_byte(TAG_VECTOR)
        write_i32(io, v.value.size.to_i32)
        v.value.each { |item| write_datum(io, item) }
      else
        raise "cvm: unsupported quasiquote literal datum type #{v.class}"
      end
    end

    private def self.write_const(io : IO, v : SchemeValue, chunk : Chunk) : Nil
      case v
      when Builtin
        # A fused op's own deopt-fallback const (Cxr/Abs/NumEq/etc.'s `d`
        # operand — see opcode.cr) — the real Builtin to fall back to when
        # the fast path's precondition fails (e.g. Cxr on a non-pair). The
        # C VM never implements that fallback (see cvm/README.md's
        # "explicitly out of scope" list) — it hard-aborts instead, since
        # this bench never actually hits one of these paths — so the real
        # object never matters; a NIL placeholder keeps the const pool's
        # indices aligned with the real Chunk's.
        io.write_byte(TAG_NIL)
      when SchemeInt, SchemeFloat, SchemeSym, SchemeStr, SchemeBool, SchemeNil, SchemeChar, Cons, SchemeVector
        # Every other const shape (including a genuine `(quote (a b c))`-
        # style literal, or, in the original bench/creme.scm-only scope,
        # HelperForm's own stashed raw `(import ...)` form — a Cons too, but
        # never inspected at runtime since HelperForm is a no-op regardless
        # of what its operand const decodes to) is just an ordinary datum —
        # reuse the general recursive serializer quasiquote's QQConst
        # payloads already need.
        write_datum(io, v)
      else
        raise "cvm: unsupported constant type #{v.class} in chunk #{chunk.name.inspect} — extend CVMSerializer.write_const"
      end
    end
  end
end
