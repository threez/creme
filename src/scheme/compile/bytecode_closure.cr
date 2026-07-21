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
  # chunk.upvalues' UpvalDesc list). Free variables are captured through this
  # explicit upvalue array rather than an enclosing env chain.
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

    # Memoizes closures for lambda literals nested directly in THIS
    # closure's own body that capture zero upvalues (VM#make_closure's own
    # caller checks that) — e.g. a `(lambda () 0)` literal re-evaluated on
    # every iteration of a tail-recursive loop. Since such a literal has no
    # free variables at all, R7RS never distinguishes separate evaluations
    # of it (eq?-identity across separate `lambda` evaluations is
    # unspecified either way), so reusing one instance is behavior-
    # preserving — and scoping the cache to THIS specific closure instance
    # (rather than sharing it across every instantiation of the enclosing
    # function, e.g. keyed only by its Chunk) keeps it correct even when
    # the enclosing function itself gets re-created under a genuinely
    # different `root_env` (e.g. the same source `eval`'d against two
    # different environments): each such re-creation is a distinct
    # BytecodeClosure instance with its own independent cache, so a nested
    # zero-upvalue closure's own `root_env` — which still matters for ITS
    # OWN GetGlobal/DefGlobal/etc., see this class's `root_env` doc comment
    # above — is never shared across root_envs that could disagree about
    # what its global references resolve to. `proto_idx` (the nested
    # closure's slot within OUR OWN chunk.protos) is the cache key since
    # one closure body can contain more than one such literal.
    def cached_zero_upvalue_closure(proto_idx : Int32, & : -> BytecodeClosure) : BytecodeClosure
      cache = @zero_upvalue_cache ||= {} of Int32 => BytecodeClosure
      cache[proto_idx] ||= yield
    end

    @zero_upvalue_cache : Hash(Int32, BytecodeClosure)?
  end

  # (case-lambda (formals body...) ...) — one BytecodeClosure per clause
  # (each independently capturing its own upvalues via a normal Closure
  # instruction), selected by argument count at call time.
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
