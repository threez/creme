# ===========================================================================
# BytecodeClosure / Upvalue — runtime values the register VM produces
# ===========================================================================

module Scheme
  # One captured upvalue cell. "Open" while the enclosing frame that owns the
  # captured register is still on the VM's call-frame stack (`registers`
  # points directly at that frame's own register array, so writes through
  # either the enclosing frame or this upvalue are instantly visible to both,
  # matching Scheme's set!-shares-the-binding semantics); "closed" once that
  # frame returns — the value is copied out into `@value` and this cell
  # becomes self-contained, since the frame's register array is gone.
  class Upvalue
    @registers : Array(SchemeValue)?
    @index : Int32
    @value : SchemeValue = NIL
    @closed : Bool = false

    def initialize(@registers : Array(SchemeValue), @index : Int32)
    end

    def get : SchemeValue
      if regs = @registers
        regs[@index]
      else
        @value
      end
    end

    def set(v : SchemeValue) : Nil
      if regs = @registers
        regs[@index] = v
      else
        @value = v
      end
    end

    def close! : Nil
      return unless regs = @registers
      @value = regs[@index]
      @registers = nil
      @closed = true
    end
  end

  # A closure produced by the register VM's Closure instruction: a compiled
  # Chunk plus the upvalue cells it captured at creation time (per
  # chunk.upvalues' UpvalDesc list). Analogous to the tree-walker's Lambda,
  # but env-chain capture is replaced by this explicit upvalue array.
  class BytecodeClosure
    include SchemeBaseValue
    getter chunk : Chunk
    getter upvalues : Array(Upvalue)
    # Where this closure's OWN GetGlobal/DefGlobal/SetGlobal/HelperForm
    # operate — the env that was live (VM#make_closure's frame.root_env)
    # when this closure was CREATED, not wherever it's later called from.
    # See CallFrame#root_env's doc comment for why this matters (a library
    # export called from unrelated user code must still resolve its own
    # free variables against the library's env).
    getter root_env : Env

    def initialize(@chunk : Chunk, @upvalues : Array(Upvalue), @root_env : Env)
    end

    def to_display(io : IO) : Nil
      io << "#<closure:" << @chunk.name << '>'
    end
  end

  # (case-lambda (formals body...) ...) — one BytecodeClosure per clause
  # (each independently capturing its own upvalues via a normal Closure
  # instruction), selected by argument count at call time. Mirrors the
  # tree-walker's CaseLambda/Lambda pairing.
  class BytecodeCaseClosure
    include SchemeBaseValue
    getter clauses : Array(BytecodeClosure)
    property name : String
    getter root_env : Env

    def initialize(@clauses : Array(BytecodeClosure), @root_env : Env, @name : String = "case-lambda")
    end

    def to_display(io : IO) : Nil
      io << "#<procedure:" << @name << '>'
    end

    def select_clause(argc : Int32) : BytecodeClosure
      @clauses.find { |clause| clause.chunk.has_rest? ? argc >= clause.chunk.param_count : argc == clause.chunk.param_count } ||
        raise SchemeRuntimeError.new("#{@name}: no matching clause for #{argc} argument(s)")
    end
  end
end
