# ===========================================================================
# Bytecode instruction set — register-based, Lua-VM-style.
# ===========================================================================
#
# Each Instruction carries an opcode plus up to three integer operands
# (a/b/c), meaning depends on the op. Registers are slots in the current
# CallFrame's window of the VM's shared register array; constants are indices
# into the owning Chunk's constant pool.

module Scheme
  enum Op
    # a=dst, b=const index. Loads chunk.consts[b] into register a.
    LoadK
    # a=dst. Loads NIL/#t/#f into register a.
    LoadNil
    LoadTrue
    LoadFalse
    # a=dst, b=src. registers[a] = registers[b].
    Move
    # a=dst, b=upvalue index.
    GetUpval
    # a=upvalue index, b=src register.
    SetUpval
    # a=dst, b=const index (a SchemeSym naming the global).
    GetGlobal
    # a=const index (name), b=src register. `define` semantics (create/overwrite).
    DefGlobal
    # a=const index (name), b=src register. `set!` semantics (must already exist).
    SetGlobal
    # a=dst, b=src1, c=src2 — fused arithmetic/comparison/vector/string/
    # bytevector primitives (mirrors ast.cr's PrimOp table).
    Add
    Sub
    Mul
    NumLt
    NumLe
    NumGt
    NumGe
    NumEq
    VecRef
    VecSet
    VecLen
    StrRef
    StrSet
    BvRef
    BvSet
    Cons
    Not
    IsNull
    IsPair
    # eq? — unlike IsNull/IsPair just above, a 2-arg predicate (a=dst,
    # b=src1, c=src2, same shape as NumEq/Cons), so it's appended here
    # rather than grouped with the unary predicates. Reuses
    # Scheme.scheme_eqv? directly (see ast.cr's PrimOp::IsEq doc comment)
    # — no deopt path, since eq?/eqv? never raise.
    IsEq
    # a=dst, b=src register, c=a car/cdr chain encoded as a bitmap with a
    # sentinel top bit (see bytecode_compiler.cr's cxr_code / vm.cr's Op::Cxr
    # arm), d=const index of the underlying cxr builtin for the deopt-on-non-
    # pair error path. Fuses the whole (scheme cxr) family — car/cdr/caar/
    # cadr/.../cddddr — into this one instruction.
    Cxr
    # a=dst, b=src register, d=const index of the underlying builtin for the
    # deopt path. Unary numeric prims that fast-path the common representation
    # inline and deopt to their builtin for the rest (tower/overflow/error):
    # Abs; CmpZero (operand c selects the test: 0 => zero?, 1 => positive?,
    # 2 => negative?).
    Abs
    CmpZero
    # a=dst, b=src1 register, c=a raw Int32 immediate value (NOT a const-pool
    # index — b OP c directly) — the small-integer-literal-as-2nd-operand
    # specialization of the arithmetic/comparison ops just above (e.g. `(< n
    # 2)`/`(- n 1)`), skipping the register + LoadK a literal would otherwise
    # need. Only emitted when the literal fits Int32 (see
    # BytecodeCompiler#imm_operand?); a literal outside that range still
    # compiles through the ordinary Add/Sub/.../LoadK path above. Only
    # literal-in-2nd-position is supported — order matters for the
    # non-commutative ops (Sub/comparisons), and this project's only hot
    # shapes are all "literal second"; a reversed variant is deliberately not
    # implemented.
    AddImm
    SubImm
    MulImm
    NumLtImm
    NumLeImm
    NumGtImm
    NumGeImm
    NumEqImm
    # eq?'s *Imm counterpart — c is always logically a SchemeInt (that's
    # all imm_operand? ever bakes), and scheme_eqv? says a non-SchemeInt
    # can never be eqv? an int, so the check is just `x.is_a?(SchemeInt)
    # && x.value == c` — no SchemeInt allocation, no fallback needed.
    IsEqImm
    # a=dst, b=src1 register, c=upvalue index of the 2nd operand (read via
    # Upvalue#get, NOT a register) — the closed-over-variable-as-2nd-operand
    # specialization of the arithmetic/comparison ops, skipping the
    # register + GetUpval a bare captured variable would otherwise need
    # (e.g. `(< i n)` where `n` is captured from an enclosing scope by a
    # named-let loop). Only upvalue-in-2nd-position is supported, same
    # rationale as *Imm's literal-in-2nd-position-only scope. Gated at
    # compile time on the 1st operand being a side-effect-free leaf (see
    # BytecodeCompiler#up_operand?), so fusing this can never observe the
    # captured variable at a different point than strict left-to-right
    # evaluation would have.
    AddUp
    SubUp
    MulUp
    NumLtUp
    NumLeUp
    NumGtUp
    NumGeUp
    NumEqUp
    # eq?'s *Up counterpart — c's upvalue read can be any runtime value
    # (unlike Imm, this isn't restricted to integers), so this always
    # calls Scheme.scheme_eqv?(x, y) in full, same as the base IsEq op.
    IsEqUp
    # a=dst, b=upvalue index of the vector, c=index register — the closed-
    # over-vector-as-object specialization of VecRef, same rationale as
    # AddUp above (e.g. `(vector-ref v i)` where `v` is captured by a
    # named-let loop). Gated on every OTHER argument being a leaf.
    VecRefUp
    # a=upvalue index of the vector, b=index register, c=value register,
    # d=dst register — VecSet's closed-over-vector specialization. Unlike
    # VecSet (whose `a` register already holds the object, so the compiler
    # just Move's it into dst afterward), there's no register holding the
    # object here — the VM handler fetches it once via the upvalue, mutates
    # through that same reference, and ALSO writes it into dst itself
    # (reusing the previously-unused `d` operand), so no second upvalue
    # read is needed for the "returns the mutated object" convention.
    VecSetUp
    # a=dst, b=upvalue index of the vector.
    VecLenUp
    StrRefUp
    StrSetUp
    BvRefUp
    BvSetUp
    # a=dst (bool), b=key register, c=const index of a SchemeVector holding
    # a case clause's datums — true iff any datum is `eqv?` the key.
    CaseMatch
    # a=key register, b=index into chunk.case_dispatch_tables. O(1)
    # counterpart of CaseMatch/TestFalse's per-clause linear scan — emitted
    # instead of that chain when BytecodeCompiler#hashable_case? finds every
    # clause's datums are all a hashable type (int/char/symbol/bool/nil) and
    # there are enough of them to be worth a table (see
    # BytecodeCompiler#compile_case_hash_dispatch). Unlike CaseMatch this
    # never materializes a boolean — it looks the key up in the table
    # directly and jumps to the matching clause's body (or the table's
    # `default`, an else clause or a shared "produce NIL" block, on a miss),
    # by setting `frame.ip` to an ABSOLUTE instruction index rather than
    # adding a relative offset like every other jump op — safe because the
    # fetch step already advances `frame.ip` past this instruction before
    # dispatch runs, so a plain assignment here lands the next fetch exactly
    # on the target instruction, same as it would after `frame.ip +=
    # relative_offset` for any other jump.
    CaseDispatch
    # a=const index of a message SchemeStr. Raises a SchemeRuntimeError when
    # REACHED at runtime (mirrors ThrowNode — a malformed form detected at
    # compile time whose error must surface only if actually executed, e.g.
    # an unreached cond/case clause after an earlier match).
    Throw
    # b=signed relative offset (from the instruction AFTER this one).
    Jmp
    # a=test register, b=signed relative offset. Jumps iff registers[a] is falsy.
    TestFalse
    # a=src1 register, b=signed relative offset, c=src2 register — a fused
    # "compare, then branch on the result" superinstruction: jumps by b iff
    # NOT (a OP c), same jump-if-falsy polarity as TestFalse, without ever
    # materializing the comparison's boolean result in a register at all.
    # Offset stays in `b` (not `c`) to match every other jump op — Chunk#
    # patch_jump_to_here always patches operand `b` unconditionally, so a
    # jump-taking op's offset must live there regardless of what its other
    # operands mean. Emitted by compile_if/compile_when in place of a
    # NumLt-family op immediately followed by TestFalse, when the if/when's
    # test expression IS exactly that comparison — safe there specifically
    # because if/when never need the test's own value, only its
    # truthiness (unlike cond/guard's clause tests, which can be the
    # clause's own result via a bodyless clause or a `=>` arrow — those
    # keep compiling through the unfused Num*+TestFalse path). Mirrors
    # Lua's own bytecode design (this VM's stated model):
    # Lua's OP_LT/OP_LE/OP_EQ are themselves conditional-skip instructions,
    # not boolean-producing ops paired with a separate test.
    TestLt
    TestLe
    TestGt
    TestGe
    TestEq
    # eq?'s fused compare+branch counterpart (same TestEq shape: a=src1,
    # b=offset, c=src2) — TestEq itself is `=`'s (NOT eq?'s), hence the
    # distinct "TestIsEq" name; see PrimOp::IsEq's doc comment. Emitted by
    # compile_fused_test exactly where a bare `(eq? x y)` is if/when's own
    # test expression.
    TestIsEq
    # a=src register, b=offset, c=raw Int32 immediate — the TestLt-family
    # counterpart of *Imm: the comparison's 2nd operand is a compile-time
    # literal instead of a register, baked directly into the instruction.
    TestLtImm
    TestLeImm
    TestGtImm
    TestGeImm
    TestEqImm
    TestIsEqImm
    # a=src register, b=offset, c=upvalue index — the TestLt-family
    # counterpart of *Up: the comparison's 2nd operand is a closed-over
    # variable read via Upvalue#get instead of a register.
    TestLtUp
    TestLeUp
    TestGtUp
    TestGeUp
    TestEqUp
    TestIsEqUp
    # a=func register (args occupy a+1..a+b), b=nargs, c=dst register (where
    # the return value is written). c is independent of a/the arg window —
    # exec_call writes the result there directly, no separate Move needed.
    Call
    # a=func register (args occupy a+1..a+b), b=nargs. Reuses the current frame.
    TailCall
    # Fused "load the callee, then call it" superinstructions — the callee is
    # NOT read from register a (a is only the contiguous-arg anchor: args
    # occupy a+1..a+b, exactly as Call/TailCall); instead `d` says where to
    # get it, eliminating the separate GetGlobal/Move/GetUpval a bare-name
    # callee would otherwise emit before Call. b=nargs; c=dst register for
    # the non-tail variants (tail variants ignore c and inherit the
    # enclosing non-tail call's return_reg, exactly like TailCall).
    #   *Global: d=const index of the callee's global name — resolved via the
    #            per-instruction global cache (get_global_cached), same fast
    #            path + redefinition safety as GetGlobal.
    #   *Local:  d=the callee's own local register — callee = @stack[base+d].
    #   *Upval:  d=upvalue index — callee = closure.upvalues[d].get.
    CallGlobal
    TailCallGlobal
    CallLocal
    TailCallLocal
    CallUpval
    TailCallUpval
    # a=register holding the return value.
    Return
    # a=const index of the global name — the ReturnGlobal/ReturnUpval pair
    # fuses a bare-name tail value's load with its own Return, skipping the
    # register write a Move/GetUpval would otherwise need purely to hand the
    # value to Return: dst is discarded the instant a call returns, so
    # there's nothing to gain by materializing the value there first. The
    # local case needs no such op at all — Return already reads from ANY
    # register, so a bare local in tail position just emits `Return
    # local_reg` directly (see compile_name_read). Resolved via the same
    # per-instruction global cache GetGlobal uses (get_global_cached).
    ReturnGlobal
    # a=upvalue index. Resolved via Upvalue#get.
    ReturnUpval
    # a=dst (scratch, same convention as the base op), b=src1, c=src2 — the
    # Return-fused counterpart of the base 2-arg arithmetic/comparison ops
    # (Add/Sub/Mul/NumLt/NumLe/NumGt/NumGe/NumEq), ONLY ever emitted by
    # compile_prim_call when the call is itself in tail position (e.g.
    # fib's `(+ (fib (- n 1)) (fib (- n 2)))`). exec_prim computes/writes
    # the result exactly like the base op (they share the same case-label
    # body there); the dispatch loop then unconditionally hands that
    # register to deliver_return instead of leaving it for a separate
    # Return instruction to read back out. Deliberately a DISTINCT enum
    # value per op — not a runtime flag checked after the base op's own
    # dispatch — so the base op's hot dispatch arm is completely untouched
    # (this codebase already measured that even an always-false runtime
    # check added to that arm regresses it; see the execute/execute_sampled
    # split's own comment above). Only the plain 2-arg path fuses this way;
    # the Imm/Up/vector-family prim shapes still emit a separate trailing
    # Return in tail position, since this fusion targets only the shape fib's
    # own tail call needs.
    AddReturn
    SubReturn
    MulReturn
    NumLtReturn
    NumLeReturn
    NumGtReturn
    NumGeReturn
    NumEqReturn
    # eq?'s Return-fused counterpart — same shape/rationale as NumEqReturn
    # just above (only the plain 2-arg path fuses this way).
    IsEqReturn
    # a=dst register, b=proto index (into chunk.protos). Builds a closure,
    # capturing upvalues per chunk.protos[b].upvalues.
    Closure
    # a=dst, b=first register of a contiguous run of `c` already-built
    # BytecodeClosure values (one per case-lambda clause, each created via
    # its own Closure instruction beforehand) — bundles them into one
    # BytecodeCaseClosure.
    MakeCaseClosure
    # a=source register (a producer's result, possibly a SchemeValues), b=
    # destination base register, c=fixed param count, d=1 if there's a rest
    # param (0 otherwise) — unpacks into dst[b..b+c) (dst[b+c] getting the
    # rest list if d=1), raising if the count doesn't match. Backs define-
    # values/let-values/let*-values' destructuring.
    Destructure
    # a=first param register, b=first newval register, c=count. For each of
    # the `c` (param, newval) pairs: applies the parameter's converter (if
    # any) to newval, saves the parameter's current value, and sets it to
    # the converted value — then pushes an UnwindAction (see vm.cr) onto
    # the VM's shared unwind stack that restores all `c` saved values.
    ParamPush
    # No operands — pops and runs the most recently pushed UnwindAction
    # (restoring parameterize's saved values, in LIFO order with any
    # dynamic-wind afters nested inside the same parameterize).
    ParamPop
    # a=condition register, b=signed relative offset (same convention as
    # Jmp) to the clause-checking code to resume at if a SchemeError is
    # raised anywhere in this frame's dynamic extent (including inside
    # deeper, non-tail calls) before a matching PopHandler runs. Installs a
    # GuardHandler recording the CURRENT depth/frame/unwind-stack mark so
    # an error can unwind straight back here regardless of how many nested
    # calls/frames it has to discard. See vm.cr's `execute` rescue clause.
    PushHandler
    # No operands — pops the most recently installed GuardHandler (guard's
    # body completed normally, so it's no longer in scope).
    PopHandler
    # No operands — re-raises the exception currently being handled (no
    # guard clause matched), for an outer handler (or the VM caller) to
    # catch. Only valid inside guard's clause-checking code.
    GuardReraise
    # a=dst, b=qq_template index (chunk.qq_templates), c=base register where
    # the template's holes' pre-evaluated values start (contiguous, in the
    # same depth-first order VM#build_qq walks the template). Reconstructs
    # the quasiquoted datum at runtime.
    Quasiquote
    # a=dst, b=register holding a 0-arg closure. Wraps it in a SchemePromise
    # (delay/delay-force).
    MakePromise
    # a=dst, b=const index of the original raw form (a Cons), c=which
    # helper to call (0=import, 1=define-library, 2=define-record-type,
    # 3=define-syntax, 4=defmacro). Only ever compiled at the top level —
    # see compile_helper_form.
    HelperForm
    # a=first target register, b=const index of the raw define-record-type
    # form, c=name count. Runs eval_define_record_type against a throwaway
    # scratch Env, then copies each of its `c` produced bindings (in
    # Scheme.record_type_names' order, which the compiler pre-declared
    # local registers for at [a, a+c)) out of that scratch env into the
    # stack. Backs a define-record-type used INSIDE a function body — see
    # compile_helper_form/pre_declare_internal_defines — since each call
    # must still produce a genuinely fresh SchemeRecordType (disjoint per
    # R7RS), unlike import/define-library/define-syntax/defmacro this can't
    # just be restricted to the top level.
    HelperFormLocal
  end

  # A single decoded bytecode instruction. `d`, when used (currently only by
  # the fused prim ops), is a const-pool index for the underlying Builtin to
  # dispatch to (from ast.cr's PRIM_OPS), so arithmetic/vector/string/
  # bytevector semantics and error messages stay identical without
  # re-implementing them here. The hottest prim shapes (integer arithmetic,
  # cxr) are further fused into direct Crystal calls in the VM dispatch loop,
  # bypassing Builtin#fn entirely; the rest still go through exec_prim.
  struct Instruction
    getter op : Op
    getter a : Int32
    getter b : Int32
    getter c : Int32
    getter d : Int32

    def initialize(@op : Op, @a : Int32 = 0, @b : Int32 = 0, @c : Int32 = 0, @d : Int32 = 0)
    end
  end

  # Describes how a closure's Nth upvalue is captured when its Closure
  # instruction runs: either directly off a still-live register in the
  # immediately enclosing function's frame (`from_parent_local = true`,
  # `index` = that register), or forwarded from the enclosing function's OWN
  # upvalue array (`from_parent_local = false`, `index` = that upvalue's
  # index there) — the standard Lua-style upvalue-chain scheme.
  struct UpvalDesc
    getter from_parent_local : Bool
    getter index : Int32
    getter name : String

    def initialize(@from_parent_local : Bool, @index : Int32, @name : String)
    end
  end
end
