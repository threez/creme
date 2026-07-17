# ===========================================================================
# Chunk: a compiled function body — the register VM's unit of compilation.
# ===========================================================================
#
# One Chunk per Lambda (including named-let loop procedures and case-lambda
# clauses) plus one top-level Chunk per program/library body. Instructions
# index into `consts` for literals/global names and into `protos` for nested
# closures (Closure's `b` operand).

module Scheme
  class Chunk
    getter instructions = [] of Instruction
    getter consts = [] of SchemeValue
    getter protos = [] of Chunk
    getter positions = [] of SourcePos?
    getter upvalues = [] of UpvalDesc
    # Number of fixed parameter registers (0..params.size-1), used by the VM
    # to bind call arguments into the new frame's window before running body.
    property param_count : Int32 = 0
    property? has_rest : Bool = false
    # High-water mark of registers this chunk's frame needs — the VM
    # allocates exactly this many registers per call.
    property num_registers : Int32 = 0
    property name : String = "lambda"
    # Per-GetGlobal-instruction inline cache, keyed on the global env's
    # version — skips the Env hash lookup entirely while nothing has
    # (re)defined the name at the global level.
    # Array-indexed by instruction index (kept 1:1 with `instructions` by
    # `emit`, below) rather than a Hash — a plain array index is cheaper
    # than hashing an Int32 key on every single GetGlobal dispatch, and the
    # small amount of unused space for non-GetGlobal instructions is
    # negligible next to that.
    getter global_cache_values = [] of SchemeValue?
    getter global_cache_versions = [] of Int32
    # QQTemplate trees for compiled `quasiquote` forms (see Op::Quasiquote/
    # VM#build_qq) — kept as compile-time Crystal objects rather than
    # serialized into the const pool, since they're only ever walked by
    # Crystal code, never handed to Scheme.
    getter qq_templates = [] of QQTemplate

    # Sparse per-instruction metadata for (creme prof)'s cooperative
    # Scheme-level sampler (see Interpreter#tick_sample/VM#execute) — keyed
    # by instruction index, populated only at the handful of compile sites
    # worth distinguishing in a profile (BytecodeCompiler#tag_sample): a
    # procedure call (kind "call", name reconstructed from the original
    # AppNode's source text), a fused primitive call (kind/name both the
    # primitive's own Scheme name, e.g. "+"), and each control construct's
    # entry point (kind "if"/"when"/"cond"/"case", name same as kind since
    # there's no single source form to reconstruct). Everything else falls
    # back to a plain Op-derived label (see Interpreter.op_label) — reading
    # this Hash only happens when a sample actually fires, so it adds zero
    # overhead to ordinary instruction dispatch.
    getter sample_tags = {} of Int32 => {String, String}

    def tag_sample(ip : Int32, kind : String, name : String = kind) : Nil
      @sample_tags[ip] = {kind, name}
    end

    def add_qq_template(t : QQTemplate) : Int32
      @qq_templates << t
      @qq_templates.size - 1
    end

    def emit(op : Op, a : Int32 = 0, b : Int32 = 0, c : Int32 = 0, d : Int32 = 0, pos : SourcePos? = nil) : Int32
      @instructions << Instruction.new(op, a, b, c, d)
      @positions << pos
      @global_cache_values << nil
      @global_cache_versions << -1
      @instructions.size - 1
    end

    def patch_jump_to_here(instr_index : Int32) : Nil
      target = @instructions.size
      old = @instructions[instr_index]
      offset = target - (instr_index + 1)
      @instructions[instr_index] = Instruction.new(old.op, old.a, offset, old.c, old.d)
    end

    # Reuse an existing identical constant to keep the pool small for hot
    # loops with repeated literals — not required for correctness, just
    # avoids pool bloat. Deliberately restricted to atomic, genuinely
    # immutable value types (Int/Float/Sym/Char) compared via scheme_eqv?'s
    # bit-pattern equality (distinguishes 0.0 from -0.0, unlike a
    # write_string comparison — SchemeFloat#to_display renders both as
    # "0.0", so a write_string-based dedup would return the WRONG constant
    # for a -0.0 literal). Never dedups mutable
    # aggregate literals (strings/pairs/vectors/bytevectors) — two textually
    # identical quoted literals sharing one object would be a real
    # correctness hazard the instant either gets mutated (string-set!,
    # vector-set!, set-car!, ...).
    def add_const(value : SchemeValue) : Int32
      if value.is_a?(SchemeInt) || value.is_a?(SchemeFloat) || value.is_a?(SchemeSym) || value.is_a?(SchemeChar)
        @consts.each_with_index do |existing, index|
          return index if existing.class == value.class && Scheme.scheme_eqv?(existing, value)
        end
      end
      @consts << value
      @consts.size - 1
    end

    def add_proto(proto : Chunk) : Int32
      @protos << proto
      @protos.size - 1
    end
  end
end
