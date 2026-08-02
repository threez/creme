# ===========================================================================
# BytecodeCompiler: Node AST -> Chunk (register bytecode)
# ===========================================================================
#
# Compiles the analyzer's existing Node tree (see ast.cr) into a register-
# based Chunk for the VM (eval/vm.cr) to run. Re-derives lexical scoping
# itself (own name->register scope chain, Lua-compiler-style) rather than
# reusing LocalRefNode/GlobalRefNode's depth/index or inline-cache fields,
# which describe an Env-chain model, not a flat per-function register window
# — walking the same Node tree in the same nesting order the analyzer did
# reproduces correct shadowing on its own.
#
# Register allocation strategy: `alloc_reg` only ever bumps a per-function
# watermark; most temps are reclaimed once their containing expression/
# statement is done (`FunctionCompiler#reclaim_to`), and a whole scope's
# worth reclaims in bulk at `pop_scope` (a let/lambda/named-let body block
# ending). `reclaim_to` never rolls back below the current scope's
# persistent_high_water, though — an internal `define` compiled as part of
# "some statement" extends the ENCLOSING scope with a genuinely persistent
# local (not a disposable temp), so a mid-scope reclaim that didn't respect
# this would silently hand that local's own register back out to some
# later, unrelated temp. This is not register-optimal (a function with many
# nested temporaries uses more registers than a liveness-tracking allocator
# would), but it is simple and unambiguously correct — a temp register is
# never reused while an in-progress subexpression (or a persistent local)
# could still reference it.
#
# Tail-call handling: nodes that have their own tail sub-position(s) (If,
# Begin, And, Or, When, Let/Let*/Letrec, NamedLet) forward the caller's
# `tail` flag down to exactly that sub-position and emit no Return
# themselves — the recursive call bottoms out at a genuine terminal (a
# value-producing node, or an AppNode) which decides Return vs TailCall.

module Creme
  class CompilerScope
    property names = {} of String => Int32
    property parent : CompilerScope?
    property saved_next_reg : Int32
    # Highest register+1 among all locals declared in this scope so far —
    # a MID-scope reclaim (discarding some statement's own disposable
    # temps, e.g. compile_body's per-statement discard register) must
    # never roll back below this, or a persistent local declared by that
    # very statement (an internal `define`, which extends the CURRENT
    # scope rather than pushing its own) would have its register silently
    # handed back out to later, unrelated temps. Scope-EXIT reclaims
    # (pop_scope) intentionally do NOT consult this — the whole scope,
    # persistent locals included, is genuinely going out of scope then.
    property persistent_high_water : Int32

    def initialize(@parent : CompilerScope?, @saved_next_reg : Int32)
      @persistent_high_water = @saved_next_reg
    end
  end

  class FunctionCompiler
    getter chunk : Chunk
    getter enclosing : FunctionCompiler?
    property next_reg : Int32 = 0
    property scope : CompilerScope?
    property? is_toplevel : Bool

    # Every register of THIS function that some nested closure, anywhere in
    # this function's body, has captured as a `from_parent_local` upvalue
    # (see resolve_upvalue) — i.e. a register some live closure may hold an
    # OPEN pointer into. compile_tail_call_args_in_place must never write
    # into one of these directly: the runtime only closes (snapshots) an
    # open upvalue right before a TailCall's own dispatch overwrites the
    # frame (close_upvalues, called from dispatch_call in both vm.cr and
    # icecreme/vm.c) — writing the new value earlier, via an ordinary preceding
    # instruction, corrupts the still-open upvalue before that protection
    # ever runs. Deliberately whole-function, not scope-local: a register
    # number gets reused by a later, unrelated scope once the capturing
    # scope pops, so this is a conservative (safe, occasionally
    # over-cautious) approximation rather than true liveness tracking.
    property captured_registers = Set(Int32).new

    def initialize(@enclosing : FunctionCompiler? = nil, name : String = "lambda", @is_toplevel : Bool = false)
      @chunk = Chunk.new
      @chunk.name = name
    end

    def alloc_reg : Int32
      r = @next_reg
      @next_reg += 1
      @chunk.num_registers = @next_reg if @next_reg > @chunk.num_registers
      r
    end

    # Reserves `n` contiguous registers in one bump, returning the first —
    # equivalent to calling alloc_reg n times and taking its first result,
    # just without the N separate calls/bounds-checks or an intermediate
    # array of results. Used where a whole contiguous run (a call's own
    # anchor+args, or callee+args) is reserved up front before any of it is
    # compiled into — see compile_app below.
    def alloc_regs(n : Int32) : Int32
      r = @next_reg
      @next_reg += n
      @chunk.num_registers = @next_reg if @next_reg > @chunk.num_registers
      r
    end

    def push_scope : Nil
      @scope = CompilerScope.new(@scope, @next_reg)
    end

    # Raises `floor` past the highest register >= `at_or_above` that some
    # closure captured as a `from_parent_local` upvalue (captured_
    # registers, above), if any — shared by pop_scope and reclaim_to
    # below, both of which would otherwise let a LATER sibling scope's
    # (or a later statement's/argument's own disposable temp's) register
    # reuse silently corrupt a still-open upvalue: such an upvalue stays
    # open (a live Value* into that very register) until frame-return/
    # tail-call time, not until whatever produced it merely finishes, so
    # reusing the register before then overwrites the closure's captured
    # value out from under it.
    #
    # Applying this at every pop_scope/reclaim_to call site (not just one
    # narrow one) was tried and initially caused real regressions in
    # compile_app's two general-path branches below: those allocate one
    # register per call argument via repeated top-level alloc_reg calls,
    # documented as relying on "nothing shrinks next_reg between these
    # allocations, so they stay contiguous" — a non-leaf argument (e.g. a
    # let/letrec with its own captured-register floor) could leave
    # next_reg higher than expected once ITS OWN scope popped, shifting
    # where a LATER argument's register landed and silently breaking
    # that contiguity (the Call/TailCall op then read the wrong
    # registers as its arguments at runtime). Fixed at the root instead
    # of narrowing this floor's own use: both branches now reserve every
    # argument's register up front, in one batch, before compiling any
    # argument's own expression (mirroring self-hosted compiler.sld's
    # compile-ordinary-app!, which already did this and was never
    # vulnerable to begin with) — so no argument's own scope-popping can
    # ever retroactively shift a sibling argument's already-fixed
    # register number. With that in place, applying this floor generally
    # here is safe and verified clean across the full spec suite.
    private def floor_respecting_captures(floor : Int32, at_or_above : Int32) : Int32
      highest_captured = @captured_registers.select { |reg| reg >= at_or_above }.max?
      highest_captured && highest_captured + 1 > floor ? highest_captured + 1 : floor
    end

    def pop_scope : Nil
      cur = @scope || raise "internal: pop_scope with no active scope"
      @next_reg = floor_respecting_captures(cur.saved_next_reg, cur.saved_next_reg)
      @scope = cur.parent
    end

    def declare_local(name : String) : Int32
      reg = alloc_reg
      scope = @scope || raise "internal: declare_local outside any scope"
      scope.names[name] = reg
      scope.persistent_high_water = reg + 1 if reg + 1 > scope.persistent_high_water
      reg
    end

    # Reclaims registers back down to `mark` — EXCEPT never below the
    # current scope's persistent_high_water (see CompilerScope's doc
    # comment), so a mid-scope reclaim can never hand out a persistent
    # local's own register to some later, unrelated temp — nor below any
    # register >= mark some closure captured as an upvalue while
    # compiling whatever is being reclaimed here (floor_respecting_
    # captures, above). Safe to call unconditionally (no scope at all —
    # true top level — just uses `mark` directly, since nothing declare_
    # local'd there needs protecting).
    def reclaim_to(mark : Int32) : Nil
      floor = @scope.try(&.persistent_high_water) || mark
      floor = floor_respecting_captures(floor, mark)
      @next_reg = mark > floor ? mark : floor
    end

    def resolve_local(name : String) : Int32?
      cur = @scope
      while cur
        if reg = cur.names[name]?
          return reg
        end
        cur = cur.parent
      end
      nil
    end

    # Unlike resolve_local, only checks the IMMEDIATE scope object — used to
    # tell "this name was already pre-declared as part of THIS body's own
    # internal defines" apart from "this name happens to be bound in some
    # enclosing scope" (which resolve_local would also match, wrongly
    # reusing an outer local's register instead of shadowing it with a new
    # one for this scope).
    def local_in_current_scope?(name : String) : Int32?
      @scope.try(&.names[name]?)
    end

    def emit(op : Op, a : Int32 = 0, b : Int32 = 0, c : Int32 = 0, d : Int32 = 0, pos : SourcePos? = nil) : Int32
      @chunk.emit(op, a, b, c, d, pos)
    end
  end

  class BytecodeCompiler
    # Used only to synthesize a non-collidable local name for `do`'s
    # desugared self-tail-recursive loop procedure (see compile_do) — an
    # instance counter is enough since one BytecodeCompiler compiles one
    # whole program/library body.
    @loop_counter = 0

    # Compiles a full top-level program (or library body): a sequence of
    # already-analyzed top-level forms, run for effect except the last form's
    # value is returned (matching Creme.run_source's per-form semantics).
    def self.compile_program(nodes : Array(Node)) : Chunk
      compiler = new
      fc = FunctionCompiler.new(nil, "program", is_toplevel: true)
      compiler.compile_body(fc, nodes, tail: true)
      compiler.append_return_sentinel(fc)
      fc.chunk
    end

    # Appends a dead LoadNil+Return to the chunk being finalized. This backs
    # the VM's bounds-check-free dispatch fetch (see vm.cr's `execute`): it
    # guarantees the chunk's last instruction is a Return, so sequential
    # execution can never run off the end, AND that the instruction array has
    # a valid index one past every possible jump target (patch_jump_to_here
    # only ever records the instruction count AT patch time, i.e. <= the size
    # before this append), so no jump can land out of range either. A
    # well-formed body already ends in a real Return, making this pair dead
    # code — reached only if a (buggy) chunk ever fell through, where it
    # preserves the historical fall-off-returns-NIL semantics rather than
    # reading past the array.
    def append_return_sentinel(fc : FunctionCompiler) : Nil
      r = fc.alloc_reg
      emit_nil(fc, r)
      fc.emit(Op::Return, r)
    end

    # Analyzes, compiles, and runs each top-level form in turn — mirroring
    # Creme.run_source's own per-form loop (runner.cr) — rather than
    # analyzing every form up front. This matters as soon as a HelperFormNode
    # is in play: a top-level (define-syntax ...)/(import ...) must actually
    # RUN (updating interp.global) before the analyzer processes any LATER
    # form, or that later form's analyze pass won't see the new macro/
    # imported bindings yet. Each form gets its own fresh VM instance —
    # harmless, since all cross-form state (globals, libraries, macros)
    # lives on Interpreter, not the VM — and its own fresh max_steps budget
    # (interp.reset_step_count), so one form's cost never eats into a later
    # form's limit.
    def self.run_program(interp : Interpreter, forms : Array(SchemeValue), env : Env? = nil) : SchemeValue
      target_env = env || interp.global
      result : SchemeValue = NIL
      forms.each do |form|
        interp.reset_step_count
        node = interp.analyze(form, target_env)
        chunk = compile_program([node])
        result = VM.new(interp, target_env).run(chunk)
      end
      result
    end

    # Compiles all but the last node for effect (discarding their values),
    # then the last node into a fresh register with the given `tail` flag.
    # An empty body evaluates to NIL (Return-ing it if tail, since a
    # zero-body lambda is itself always compiled as one — used by top-level
    # programs where `tail` is false, the value simply isn't consumed).
    def compile_body(fc : FunctionCompiler, nodes : Array(Node), tail : Bool) : Int32
      if nodes.empty?
        dst = fc.alloc_reg
        emit_nil(fc, dst)
        fc.emit(Op::Return, dst) if tail
        return dst
      end
      pre_declare_internal_defines(fc, nodes)
      nodes[0...-1].each do |node|
        mark = fc.next_reg
        discard = fc.alloc_reg
        compile_expr(fc, node, discard, false)
        fc.reclaim_to(mark)
      end
      dst = fc.alloc_reg
      compile_expr(fc, nodes.last, dst, tail)
      dst
    end

    # Internal defines behave like letrec* (R7RS §5.3): a name defined
    # partway through a body must still be resolvable — as a local, or
    # captured as an upvalue by an EARLIER-defined closure in the same body
    # — by anything else in that body, even something compiled before its
    # own `define` runs (mutual recursion between two internal defines is
    # the common case: `(define (foo x) (bar x)) (define (bar x) ...)`).
    # Since this compiler resolves names once, at compile time, by walking
    # the scope chain, a name only becomes resolvable once declare_local
    # has run for it — so every internal define at this body's own level
    # (not recursing into a nested lambda/let's own body) is pre-declared
    # up front, before compiling ANY of the body's statements. Each
    # define's own compile_expr arm then reuses the pre-declared register
    # (via local_in_current_scope?) instead of trying to allocate a new one.
    private def pre_declare_internal_defines(fc : FunctionCompiler, nodes : Array(Node)) : Nil
      return if fc.scope.nil? && fc.is_toplevel?
      nodes.each do |node|
        case node
        when DefineNode
          fc.declare_local(node.name) unless fc.local_in_current_scope?(node.name)
        when DefineValuesNode
          values_names(node.params, node.rest).each do |name|
            fc.declare_local(name) unless fc.local_in_current_scope?(name)
          end
        when HelperFormNode
          if node.kind == HelperForm::DefineRecordType
            Creme.record_type_names(node.form).try do |names|
              names.each { |name| fc.declare_local(name) unless fc.local_in_current_scope?(name) }
            end
          end
        end
      end
    end

    private def emit_nil(fc : FunctionCompiler, dst : Int32) : Nil
      ip = fc.emit(Op::LoadNil, dst)
      fc.chunk.tag_sample(ip, "literal", "()")
    end

    private def emit_load_literal(fc : FunctionCompiler, dst : Int32, value : SchemeValue) : Nil
      ip = case value
           when SchemeNil
             fc.emit(Op::LoadNil, dst)
           when SchemeBool
             fc.emit(value.value? ? Op::LoadTrue : Op::LoadFalse, dst)
           else
             fc.emit(Op::LoadK, dst, fc.chunk.add_const(value))
           end
      fc.chunk.tag_sample(ip, "literal", value.write_string)
    end

    # Resolves `name` against fc's own scope chain, then (recursively, adding
    # upvalue entries as needed) against enclosing functions' scopes, falling
    # back to :global when no enclosing function binds it either.
    private def resolve_variable(fc : FunctionCompiler, name : String) : {Symbol, Int32}
      if reg = fc.resolve_local(name)
        return {:local, reg}
      end
      if idx = resolve_upvalue(fc, name)
        return {:upvalue, idx}
      end
      {:global, 0}
    end

    private def resolve_upvalue(fc : FunctionCompiler, name : String) : Int32?
      parent = fc.enclosing
      return nil unless parent
      if reg = parent.resolve_local(name)
        parent.captured_registers.add(reg)
        return add_upvalue(fc, true, reg, name)
      end
      if idx = resolve_upvalue(parent, name)
        return add_upvalue(fc, false, idx, name)
      end
      nil
    end

    private def add_upvalue(fc : FunctionCompiler, from_parent_local : Bool, index : Int32, name : String) : Int32
      fc.chunk.upvalues.each_with_index do |existing, i|
        return i if existing.from_parent_local? == from_parent_local && existing.index == index
      end
      fc.chunk.upvalues << UpvalDesc.new(from_parent_local, index, name)
      fc.chunk.upvalues.size - 1
    end

    # `tail`: when true, this read is immediately returned — dst is
    # discarded the instant the call returns, so there's nothing to gain by
    # materializing the value there first. A local just Returns straight
    # from its own register (Return already accepts any register, no new
    # op needed); a global/upvalue has no register to already be in, so
    # ReturnGlobal/ReturnUpval resolve and deliver directly, skipping the
    # register write GetGlobal/GetUpval would otherwise need.
    private def compile_name_read(fc : FunctionCompiler, name : String, dst : Int32, tail : Bool) : Nil
      kind, idx = resolve_variable(fc, name)
      if tail
        ip = case kind
             when :local
               fc.emit(Op::Return, idx)
             when :upvalue
               fc.emit(Op::ReturnUpval, idx)
             else
               fc.emit(Op::ReturnGlobal, fc.chunk.add_const(SchemeSym.of(name)))
             end
        fc.chunk.tag_sample(ip, "return", name)
        return
      end
      case kind
      when :local
        return if dst == idx
        ip = fc.emit(Op::Move, dst, idx)
        fc.chunk.tag_sample(ip, "local-ref", name)
      when :upvalue
        ip = fc.emit(Op::GetUpval, dst, idx)
        fc.chunk.tag_sample(ip, "upval-ref", name)
      else
        ip = fc.emit(Op::GetGlobal, dst, fc.chunk.add_const(SchemeSym.of(name)))
        fc.chunk.tag_sample(ip, "global-ref", name)
      end
    end

    private def compile_name_write(fc : FunctionCompiler, name : String, src : Int32, define : Bool) : Nil
      if define && (fc.scope.nil? && fc.is_toplevel?)
        fc.emit(Op::DefGlobal, fc.chunk.add_const(SchemeSym.of(name)), src)
        return
      end
      kind, idx = resolve_variable(fc, name)
      case kind
      when :local
        fc.emit(Op::Move, idx, src) unless idx == src
      when :upvalue
        fc.emit(Op::SetUpval, idx, src)
      else
        fc.emit(define ? Op::DefGlobal : Op::SetGlobal, fc.chunk.add_const(SchemeSym.of(name)), src)
      end
    end

    # ameba:disable Metrics/CyclomaticComplexity
    def compile_expr(fc : FunctionCompiler, node : Node, dst : Int32, tail : Bool) : Nil
      case node
      when LiteralNode
        emit_load_literal(fc, dst, node.value)
        fc.emit(Op::Return, dst) if tail
      when VarRefNode
        compile_name_read(fc, node.name, dst, tail)
      when LocalRefNode
        compile_name_read(fc, node.name, dst, tail)
      when GlobalRefNode
        compile_name_read(fc, node.name, dst, tail)
      when DefineNode
        mark = fc.next_reg
        value_reg = fc.alloc_reg
        compile_expr(fc, node.value, value_reg, false)
        if fc.scope.nil? && fc.is_toplevel?
          # No local declared here — value_reg is a disposable temp, safe
          # to reclaim.
          compile_name_write(fc, node.name, value_reg, true)
          fc.reclaim_to(mark)
        else
          # An internal define grows the CURRENT scope with a genuinely new,
          # persistent local. Its register was already reserved by
          # pre_declare_internal_defines (so forward references from an
          # earlier statement in this same body resolve correctly) — reuse
          # it via local_in_current_scope? rather than declare_local'ing a
          # second, different register for the same name. Do NOT reclaim
          # next_reg back down to `mark` here: that would roll back past
          # the local's own register too (since it was reserved above
          # value_reg's), letting later code in this same function silently
          # reuse and overwrite it.
          reg = fc.local_in_current_scope?(node.name) || fc.declare_local(node.name)
          fc.emit(Op::Move, reg, value_reg) unless reg == value_reg
        end
        emit_load_literal(fc, dst, SchemeSym.of(node.name))
        fc.emit(Op::Return, dst) if tail
      when SetBangNode
        # A set! expression evaluates to the value assigned, not an
        # unspecified/NIL result.
        compile_expr(fc, node.value, dst, false)
        compile_name_write(fc, node.name, dst, false)
        fc.emit(Op::Return, dst) if tail
      when ThrowNode
        # A malformed form the analyzer detected but whose error must
        # surface only if actually REACHED at runtime (e.g. inside an
        # untaken if-branch, or a cond/case clause after an earlier match)
        # — must NOT raise here at compile time, since compiling a Chunk
        # ahead of time visits every branch regardless of whether it'll
        # ever run.
        fc.emit(Op::Throw, fc.chunk.add_const(SchemeStr.new(node.message)))
      when IfNode
        compile_if(fc, node, dst, tail)
      when BeginNode
        compile_seq_tail(fc, node.body, dst, tail)
      when AndNode
        compile_and_or(fc, node.exprs, dst, tail, is_and: true)
      when OrNode
        compile_and_or(fc, node.exprs, dst, tail, is_and: false)
      when WhenNode
        compile_when(fc, node, dst, tail)
      when LetNode
        compile_let(fc, node.names, node.inits, node.body, dst, tail, sequential: false, recursive: false)
      when LetStarNode
        compile_let(fc, node.names, node.inits, node.body, dst, tail, sequential: true, recursive: false)
      when LetrecNode
        compile_let(fc, node.names, node.inits, node.body, dst, tail, sequential: false, recursive: true)
      when NamedLetNode
        compile_named_let(fc, node, dst, tail)
      when LambdaNode
        compile_lambda(fc, node.params, node.rest, node.body_nodes, node.name, dst)
        fc.emit(Op::Return, dst) if tail
      when PrimCallNode
        fused = compile_prim_call(fc, node, dst, tail)
        fc.emit(Op::Return, dst) if tail && !fused
      when CondNode
        compile_cond_clauses(fc, node.clauses, 0, dst, tail)
      when CaseNode
        compile_case(fc, node, dst, tail)
      when DoNode
        compile_do(fc, node, dst, tail)
      when CaseLambdaNode
        compile_case_lambda(fc, node, dst)
        fc.emit(Op::Return, dst) if tail
      when DefineValuesNode
        compile_define_values(fc, node, dst, tail)
      when LetValuesNode
        compile_let_values(fc, node, dst, tail)
      when ParameterizeNode
        compile_parameterize(fc, node, dst, tail)
      when GuardNode
        compile_guard(fc, node, dst, tail)
      when QuasiquoteNode
        compile_quasiquote(fc, node, dst)
        fc.emit(Op::Return, dst) if tail
      when DelayNode
        compile_delay(fc, node, dst)
        fc.emit(Op::Return, dst) if tail
      when HelperFormNode
        compile_helper_form(fc, node, dst)
        fc.emit(Op::Return, dst) if tail
      when AppNode
        compile_app(fc, node, dst, tail)
      else
        raise SchemeRuntimeError.new("bytecode VM: #{node.class} is not yet implemented")
      end
    end

    # If `node` is a bare 2-arg comparison call, the base (non-Imm/Up)
    # fused-branch Op it maps to — else nil. Mirrors compile_prim_call's
    # own PrimOp->Op mapping for exactly the 6 comparison-shaped ops
    # (the 5 numeric comparisons plus eq?).
    private def comparison_op_of(node : Node) : Op?
      return nil unless node.is_a?(PrimCallNode) && node.args.size == 2
      case node.op
      when PrimOp::NumLt then Op::NumLt
      when PrimOp::NumLe then Op::NumLe
      when PrimOp::NumGt then Op::NumGt
      when PrimOp::NumGe then Op::NumGe
      when PrimOp::NumEq then Op::NumEq
      when PrimOp::IsEq  then Op::IsEq
      else                    nil
      end
    end

    private def test_op_for(op : Op) : Op?
      case op
      when Op::NumLt then Op::TestLt
      when Op::NumLe then Op::TestLe
      when Op::NumGt then Op::TestGt
      when Op::NumGe then Op::TestGe
      when Op::NumEq then Op::TestEq
      when Op::IsEq  then Op::TestIsEq
      else                nil
      end
    end

    private def test_imm_op_for(op : Op) : Op?
      case op
      when Op::NumLt then Op::TestLtImm
      when Op::NumLe then Op::TestLeImm
      when Op::NumGt then Op::TestGtImm
      when Op::NumGe then Op::TestGeImm
      when Op::NumEq then Op::TestEqImm
      when Op::IsEq  then Op::TestIsEqImm
      else                nil
      end
    end

    private def test_up_op_for(op : Op) : Op?
      case op
      when Op::NumLt then Op::TestLtUp
      when Op::NumLe then Op::TestLeUp
      when Op::NumGt then Op::TestGtUp
      when Op::NumGe then Op::TestGeUp
      when Op::NumEq then Op::TestEqUp
      when Op::IsEq  then Op::TestIsEqUp
      else                nil
      end
    end

    # If `test` is a bare 2-arg comparison call, compiles a fused Test*
    # instruction (same jump-if-falsy polarity as TestFalse) instead of
    # materializing the comparison's boolean result into a register first,
    # returning the jump instruction's index (to patch later, exactly like
    # a plain TestFalse) — or nil if `test` isn't this shape, so the
    # caller falls back to the general compile_expr+TestFalse path. Safe
    # specifically for if/when, whose test value is only ever used for
    # truthiness — NOT reused for cond/guard, whose clause tests can also
    # BE the clause's own result (a bodyless clause, or a `=>` arrow).
    private def compile_fused_test(fc : FunctionCompiler, test : Node, tag : String) : Int32?
      op = comparison_op_of(test)
      return nil unless op
      node = test.as(PrimCallNode)
      prim_src = node.src.write_string
      if (imm_op = test_imm_op_for(op)) && (imm = imm_operand?(node.args[1]))
        mark = fc.next_reg
        first_reg = local_register_of?(fc, node.args[0]) || begin
          r = fc.alloc_reg
          compile_expr(fc, node.args[0], r, false)
          r
        end
        fc.reclaim_to(mark)
        jmp = fc.emit(imm_op, first_reg, 0, imm)
        fc.chunk.tag_sample(jmp, tag, prim_src)
        return jmp
      end
      if (up_op = test_up_op_for(op)) && (up_idx = up_operand?(fc, node.args[1])) && leaf_node?(node.args[0])
        mark = fc.next_reg
        first_reg = local_register_of?(fc, node.args[0]) || begin
          r = fc.alloc_reg
          compile_expr(fc, node.args[0], r, false)
          r
        end
        fc.reclaim_to(mark)
        jmp = fc.emit(up_op, first_reg, 0, up_idx)
        fc.chunk.tag_sample(jmp, tag, prim_src)
        return jmp
      end
      base_op = test_op_for(op)
      return nil unless base_op
      mark = fc.next_reg
      all_leaves = node.args.all? { |arg| leaf_node?(arg) }
      arg_regs = node.args.map do |arg|
        if all_leaves && (local_reg = local_register_of?(fc, arg))
          local_reg
        else
          r = fc.alloc_reg
          compile_expr(fc, arg, r, false)
          r
        end
      end
      fc.reclaim_to(mark)
      jmp = fc.emit(base_op, arg_regs[0], 0, arg_regs[1])
      fc.chunk.tag_sample(jmp, tag, prim_src)
      jmp
    end

    # Strip leading `not` wrappers from a truthiness-only test, returning the
    # unwrapped inner test and whether the sense is inverted (each `not` flips
    # it). `(if (not X) a b)` ≡ `(if X b a)` exactly — both only consult the
    # test's truthiness — so folding the `not` away lets the inner test (often a
    # comparison) fuse into a single compare-and-branch instead of paying a
    # separate `not` (and boolean materialization). Only genuine PrimOp::Not
    # nodes peel, so a shadowed/redefined `not` is untouched.
    private def peel_not(test : Node) : {Node, Bool}
      inverted = false
      while test.is_a?(PrimCallNode) && test.op == PrimOp::Not
        test = test.args[0]
        inverted = !inverted
      end
      {test, inverted}
    end

    # Compile an if/when branch that may be absent (evaluates to unspecified).
    private def compile_branch(fc : FunctionCompiler, branch : Node?, dst : Int32, tail : Bool) : Nil
      if branch
        compile_expr(fc, branch, dst, tail)
      else
        emit_nil(fc, dst)
        fc.emit(Op::Return, dst) if tail
      end
    end

    private def compile_if(fc : FunctionCompiler, node : IfNode, dst : Int32, tail : Bool) : Nil
      test, inverted = peel_not(node.test)
      then_branch = inverted ? node.alt : node.conseq
      else_branch = inverted ? node.conseq : node.alt
      jmp_false = compile_fused_test(fc, test, "if") || begin
        mark = fc.next_reg
        test_reg = fc.alloc_reg
        compile_expr(fc, test, test_reg, false)
        fc.reclaim_to(mark)
        jmp = fc.emit(Op::TestFalse, test_reg, 0)
        fc.chunk.tag_sample(jmp, "if")
        jmp
      end
      compile_branch(fc, then_branch, dst, tail)
      jmp_end = fc.emit(Op::Jmp, 0, 0) unless tail
      fc.chunk.patch_jump_to_here(jmp_false)
      compile_branch(fc, else_branch, dst, tail)
      fc.chunk.patch_jump_to_here(jmp_end) if jmp_end
    end

    private def compile_seq_tail(fc : FunctionCompiler, body : Array(Node), dst : Int32, tail : Bool) : Nil
      if body.empty?
        emit_nil(fc, dst)
        fc.emit(Op::Return, dst) if tail
        return
      end
      pre_declare_internal_defines(fc, body)
      body[0...-1].each do |node|
        mark = fc.next_reg
        discard = fc.alloc_reg
        compile_expr(fc, node, discard, false)
        fc.reclaim_to(mark)
      end
      compile_expr(fc, body.last, dst, tail)
    end

    # `and` short-circuits (to `dst`, holding the culprit value) on the first
    # falsy expr; `or` short-circuits on the first truthy expr. There's no
    # native "jump if truthy" op, so `or` inverts via TestFalse-then-skip: if
    # the value IS false, skip over the unconditional short-circuit jump and
    # fall through to evaluate the next expr instead.
    #
    # The last expr is only compiled in genuine tail position (a TailCall,
    # if it's itself a call) when there's exactly one expr — with 2+ exprs,
    # earlier short-circuit jumps must land on a common merge point that
    # still emits Return, so the last expr is compiled non-tail there and
    # Return is emitted once, uniformly, after the merge point.
    private def compile_and_or(fc : FunctionCompiler, exprs : Array(Node), dst : Int32, tail : Bool, is_and : Bool) : Nil
      if exprs.empty?
        emit_load_literal(fc, dst, is_and ? TRUE : FALSE)
        fc.emit(Op::Return, dst) if tail
        return
      end
      if exprs.size == 1
        compile_expr(fc, exprs[0], dst, tail)
        return
      end
      jumps_to_end = [] of Int32
      exprs[0...-1].each do |expr|
        compile_expr(fc, expr, dst, false)
        if is_and
          jumps_to_end << fc.emit(Op::TestFalse, dst, 0)
        else
          skip_short_circuit = fc.emit(Op::TestFalse, dst, 0)
          jumps_to_end << fc.emit(Op::Jmp, 0, 0)
          fc.chunk.patch_jump_to_here(skip_short_circuit)
        end
      end
      compile_expr(fc, exprs.last, dst, false)
      jumps_to_end.each { |j| fc.chunk.patch_jump_to_here(j) }
      fc.emit(Op::Return, dst) if tail
    end

    # (when test body...) runs body iff test is true, else evaluates to NIL;
    # (unless ...) is the mirror image — modeled directly on compile_if with
    # body/nil swapped by `negate?`, rather than a separate ad-hoc encoding.
    private def compile_when(fc : FunctionCompiler, node : WhenNode, dst : Int32, tail : Bool) : Nil
      # A `not` in the test just flips when<->unless (each one toggles the
      # negate sense), dropping the `not` instruction — see peel_not.
      test, inverted = peel_not(node.test)
      negate = node.negate? ^ inverted
      tag = negate ? "unless" : "when"
      jmp_false = compile_fused_test(fc, test, tag) || begin
        mark = fc.next_reg
        test_reg = fc.alloc_reg
        compile_expr(fc, test, test_reg, false)
        fc.reclaim_to(mark)
        jmp = fc.emit(Op::TestFalse, test_reg, 0)
        fc.chunk.tag_sample(jmp, tag)
        jmp
      end
      if negate
        emit_nil(fc, dst)
        fc.emit(Op::Return, dst) if tail
        jmp_end = fc.emit(Op::Jmp, 0, 0) unless tail
        fc.chunk.patch_jump_to_here(jmp_false)
        compile_seq_tail(fc, node.body, dst, tail)
        fc.chunk.patch_jump_to_here(jmp_end) if jmp_end
      else
        compile_seq_tail(fc, node.body, dst, tail)
        jmp_end = fc.emit(Op::Jmp, 0, 0) unless tail
        fc.chunk.patch_jump_to_here(jmp_false)
        emit_nil(fc, dst)
        fc.emit(Op::Return, dst) if tail
        fc.chunk.patch_jump_to_here(jmp_end) if jmp_end
      end
    end

    private def compile_let(fc : FunctionCompiler, names : Array(String), inits : Array(Node), body : Array(Node),
                            dst : Int32, tail : Bool, sequential : Bool, recursive : Bool) : Nil
      fc.push_scope
      if recursive
        regs = names.map { |name| fc.declare_local(name) }
        inits.each_with_index { |init, i| compile_expr(fc, init, regs[i], false) }
      elsif sequential
        names.each_with_index do |name, i|
          reg = fc.declare_local(name)
          compile_expr(fc, inits[i], reg, false)
        end
      else
        mark = fc.next_reg
        init_regs = inits.map { |init| r = fc.alloc_reg; compile_expr(fc, init, r, false); r }
        fc.reclaim_to(mark)
        names.each_with_index do |name, i|
          reg = fc.declare_local(name)
          fc.emit(Op::Move, reg, init_regs[i]) unless reg == init_regs[i]
        end
      end
      compile_seq_tail(fc, body, dst, tail)
      fc.pop_scope
    end

    # The recognized shape of a "simple counted loop" (see try_compile_
    # counted_loop below): `prefix` are the recurse-branch's own leading
    # (non-tail, side-effecting) statements, and `call` is its trailing
    # self-tail-call to the loop's own name.
    private record CountedLoopCall, prefix : Array(Node), call : AppNode

    # If `branch` is (or ends in, via a single top-level Begin) an AppNode
    # calling `loop_name` with exactly `arity` args, splits it into its
    # leading statements and that call. Returns nil for anything else
    # (a plain value, a nested if, a call to something other than
    # loop_name, wrong arity, ...) — the caller's cue to try the OTHER
    # branch instead, or give up and fall back to the ordinary closure path.
    private def split_tail_self_call(branch : Node, loop_name : String, arity : Int32) : CountedLoopCall?
      prefix = [] of Node
      last = branch
      if branch.is_a?(BeginNode)
        return nil if branch.body.empty?
        prefix = branch.body[0...-1]
        last = branch.body.last
      end
      return nil unless last.is_a?(AppNode)
      # A named-let/do's own recursive reference to its loop name is
      # lexically addressed (analyzer.cr's analyze_named_let extends the
      # scope with loop_name as its own one-name frame), so it resolves to
      # a LocalRefNode, not a VarRefNode — despite LocalRefNode's own doc
      # comment describing it as "only for param/rest slots", a named-let's
      # hidden loop-procedure binding is exactly that from the analyzer's
      # perspective. A plain self-recursive `(define (f ...) ...)`'s own
      # reference to `f` resolves to a GlobalRefNode instead (the analyzer
      # already knows `f` at the point it analyzes f's own body, since a
      # top-level define's name is visible process-wide from then on) —
      # try_compile_global_counted_loop is the only caller that can ever
      # reach this arm, since named-let/do's own loop name is never a
      # global.
      callee = last.callee
      callee_name = case callee
                    when VarRefNode    then callee.name
                    when LocalRefNode  then callee.name
                    when GlobalRefNode then callee.name
                    else                    return nil
                    end
      return nil unless callee_name == loop_name
      return nil unless last.args.size == arity
      CountedLoopCall.new(prefix, last)
    end

    # If `arg` is exactly `(+ counter_name k)`/`(- counter_name k)` for a
    # nonzero integer literal `k` that fits an Int32, the step this
    # recursive call advances `counter_name` by (negative for `-`) — else
    # nil, telling the recognizer this param isn't (or isn't provably) a
    # simple constant-step counter.
    private def step_delta(arg : Node, counter_name : String) : Int32?
      return nil unless arg.is_a?(PrimCallNode) && arg.args.size == 2
      first = arg.args[0]
      name = case first
             when VarRefNode   then first.name
             when LocalRefNode then first.name
             else                   return nil
             end
      return nil unless name == counter_name
      second = arg.args[1]
      return nil unless second.is_a?(LiteralNode)
      value = second.value
      return nil unless value.is_a?(SchemeInt)
      k = value.value
      return nil if k == 0 || k > Int32::MAX.to_i64 || k < Int32::MIN.to_i64
      case arg.op
      when PrimOp::Add then k.to_i32
      when PrimOp::Sub then -k.to_i32
      else                  nil
      end
    end

    # The recognized shape of a "simple counted loop" (see detect_counted_
    # loop_shape below) — everything try_compile_counted_loop/try_compile_
    # global_counted_loop need to know to LOWER the loop, already validated
    # against every hard requirement.
    private record CountedLoopShape,
      counter_index : Int32,
      step : Int32,
      limit_delta : Int32,
      bound_node : Node,
      split : CountedLoopCall,
      base_branch : Node

    # Tries to recognize `(let loop ((p init)...) (if test base-case
    # (begin ...prefix... (loop step...))))` — or the equivalent shape
    # `compile_do` synthesizes for `do`, or a plain self-recursive `(define
    # (f params...) body)` (see try_compile_global_counted_loop) — as a
    # "simple counted loop": one bound variable (the "counter") stepped by
    # a compile-time-constant integer add/sub, tested against a
    # loop-invariant bound, with no lambda/case-lambda literal anywhere in
    # the body (the syntactic escape-safety condition — see contains_
    # lambda?'s own doc comment) and `loop_name` referenced nowhere but that
    # one recognized tail call. Returns nil — the caller's cue to fall back
    # to its own ordinary (non-fused) path — the moment any condition
    # fails; every check is a hard requirement, not a best-effort heuristic.
    #
    # Other bound variables (accumulators like a running sum or count) are
    # NOT required to fit any particular shape — they just become ordinary
    # persistent registers, recomputed from a fresh temp each iteration
    # exactly the way a real tail call's arg-evaluation-then-rebind already
    # works, so arbitrary accumulator step expressions are fine; only the
    # counter's own step must be this constant-integer shape, since that's
    # the one Op::ForLoop/Op::ForLoopGuardedInc/Dec themselves need to
    # understand.
    # ameba:disable Metrics/CyclomaticComplexity
    private def detect_counted_loop_shape(loop_name : String, params : Array(String), body : Array(Node)) : CountedLoopShape?
      return nil unless body.size == 1 && body[0].is_a?(IfNode)
      if_node = body[0].as(IfNode)
      # A missing alt (`(if test conseq)`, no else) means "evaluate to NIL" —
      # the common no-accumulator "for-each"-style loop shape (e.g.
      # `(let loop ((i 0)) (if (< i n) (begin ...(loop (+ i 1))))))`, only
      # ever reachable as the non-recursive branch: with no explicit alt
      # there is nowhere else for a recursive call to appear.
      alt : Node = if_node.alt || LiteralNode.new(NIL)

      test, inverted = peel_not(if_node.test)
      then_branch = inverted ? alt : if_node.conseq
      else_branch = inverted ? if_node.conseq : alt

      cmp_op = comparison_op_of(test)
      return nil unless cmp_op && cmp_op != Op::IsEq
      cmp = test.as(PrimCallNode)
      counter_candidate = cmp.args[0]
      counter_name = case counter_candidate
                     when VarRefNode   then counter_candidate.name
                     when LocalRefNode then counter_candidate.name
                     else                   return nil
                     end
      counter_index = params.index(counter_name)
      return nil unless counter_index
      bound_node = cmp.args[1]
      return nil if params.any? { |param| references_name?(bound_node, param) }
      return nil if contains_lambda?(bound_node)

      recurse_in_conseq, split, base_branch =
        if s = split_tail_self_call(then_branch, loop_name, params.size)
          {true, s, else_branch}
        elsif s = split_tail_self_call(else_branch, loop_name, params.size)
          {false, s, then_branch}
        else
          return nil
        end

      return nil if contains_lambda?(base_branch) || references_name?(base_branch, loop_name)
      split.prefix.each do |stmt|
        return nil if contains_lambda?(stmt) || references_name?(stmt, loop_name)
      end
      split.call.args.each do |arg|
        return nil if contains_lambda?(arg) || references_name?(arg, loop_name)
      end

      step = step_delta(split.call.args[counter_index], counter_name)
      return nil unless step && step != 0

      # Translate whatever the source test means into Op::ForPrep/Op::ForLoop's
      # own INCLUSIVE-of-limit convention (see opcode.cr's doc comment) — the
      # limit register always holds a value such that "continue while step > 0
      # ? counter <= limit : counter >= limit" reproduces the source's exact
      # iteration count.
      limit_delta = if recurse_in_conseq
                      case cmp_op
                      when Op::NumLt then return nil unless step > 0
                      -1
                      when Op::NumLe then return nil unless step > 0
                      0
                      when Op::NumGt then return nil unless step < 0
                      1
                      when Op::NumGe then return nil unless step < 0
                      0
                      else return nil
                      end
                    else
                      case cmp_op
                      when Op::NumGe then return nil unless step > 0
                      -1
                      when Op::NumLe then return nil unless step < 0
                      1
                      when Op::NumEq then return nil unless step == 1 || step == -1
                      step > 0 ? -1 : 1
                      else return nil
                      end
                    end

      CountedLoopShape.new(counter_index, step, limit_delta, bound_node, split, base_branch)
    end

    # Shared by try_compile_counted_loop/try_compile_global_counted_loop: once a
    # CountedLoopShape is recognized and `param_regs` already hold the loop's current
    # values (either freshly Move'd-in from inits, or — for the global case — a
    # function's own already-bound param registers), emits the limit-register setup,
    # ForPrep, the per-iteration prefix/step-expression evaluation, and the terminal
    # ForLoop/ForLoopGuardedInc/Dec — but NOT the base-case compile at the end, since the
    # two callers differ there (plain vs guarded-with-a-deopt-fallback). `d_value` is the
    # terminal loop instruction's own `d`: ForLoop's step immediate for the plain
    # (unguarded) case, or a global-name const-pool index for the guarded case
    # (ForLoopGuardedInc/Dec ignore it as a step — it's implicit in which of the two ops
    # `loop_op` is — see opcode.cr's own doc comment). ForPrep, by contrast, ALWAYS gets
    # the real shape.step regardless of `d_value` — it's shared unconditionally between
    # both lowerings and its own zero-trip check (vm.cr/vm.c) has no "guarded" flavor to
    # imply the step from, so it must see the genuine step every time. Returns
    # {counter_reg, limit_reg} for the caller to finish with.
    private def emit_counted_loop(fc : FunctionCompiler, params : Array(String), param_regs : Array(Int32),
                                  shape : CountedLoopShape, loop_op : Op, d_value : Int32) : {Int32, Int32}
      mark2 = fc.next_reg
      limit_tmp = fc.alloc_reg
      compile_expr(fc, shape.bound_node, limit_tmp, false)
      fc.reclaim_to(mark2)
      limit_reg = fc.declare_local("%for-limit-#{@loop_counter += 1}")
      fc.emit(Op::Move, limit_reg, limit_tmp) unless limit_reg == limit_tmp
      fc.emit(Op::AddImm, limit_reg, limit_reg, shape.limit_delta) unless shape.limit_delta == 0

      counter_reg = param_regs[shape.counter_index]
      # ForPrep is unconditionally shared between the plain and guarded lowerings and
      # ALWAYS reads its own `d` as the real step for its zero-trip check (vm.cr/vm.c) —
      # unlike the terminal loop op, it has no "guarded" flavor of its own to imply the
      # step, so it must always get shape.step here even when `d_value` (below) is
      # actually a global const index for the guarded case.
      prep_ip = fc.emit(Op::ForPrep, counter_reg, 0, limit_reg, shape.step)
      body_start = fc.chunk.instructions.size

      shape.split.prefix.each do |stmt|
        mark3 = fc.next_reg
        discard = fc.alloc_reg
        compile_expr(fc, stmt, discard, false)
        fc.reclaim_to(mark3)
      end

      # Every carried variable's new value must be computed from every OTHER
      # carried variable's OLD value — Scheme's simultaneous-rebind semantics
      # (`(loop step...)` evaluates all step exprs against the current
      # bindings before any of them takes effect) — but that only actually
      # requires a temp register + deferred Move for a variable some OTHER
      # step expression still reads (needs_temp, below): if nothing else's
      # step expression references params[i] at all, nothing downstream can
      # observe whether its own register was overwritten early or late, so
      # its step expression can just target param_regs[i] directly — no
      # temp, no Move, exactly what a plain mutable local (Lua's own `acc =
      # acc + x`) costs. The common case (one accumulator, e.g. build-list's
      # `acc`/vector-sum-test's running sum) always qualifies as direct.
      mark4 = fc.next_reg
      other = (0...params.size).reject { |i| i == shape.counter_index }
      needs_temp = other.select do |i|
        other.any? { |j| j != i && references_name?(shape.split.call.args[j], params[i]) }
      end
      direct = other - needs_temp
      temp_pairs = needs_temp.map { |i| r = fc.alloc_reg; compile_expr(fc, shape.split.call.args[i], r, false); {i, r} }
      direct.each { |i| compile_expr(fc, shape.split.call.args[i], param_regs[i], false) }
      temp_pairs.each { |i, reg| fc.emit(Op::Move, param_regs[i], reg) unless param_regs[i] == reg }
      fc.reclaim_to(mark4)

      loop_ip = fc.emit(loop_op, counter_reg, 0, limit_reg, d_value)
      fc.chunk.instructions[loop_ip] = Instruction.new(loop_op, counter_reg, body_start - (loop_ip + 1), limit_reg, d_value)
      fc.chunk.patch_jump_to_here(prep_ip)
      {counter_reg, limit_reg}
    end

    # Recognizes and lowers a let-loop/do counted loop directly to Op::ForPrep/Op::
    # ForLoop over plain mutable registers (no closure, no per-iteration Call/TailCall).
    # See detect_counted_loop_shape's own doc comment for the recognized shape and every
    # hard requirement; returns false — emitting NOTHING, safe to retry via the ordinary
    # compile_lambda+Call/TailCall path — the moment any of them fails.
    private def try_compile_counted_loop(fc : FunctionCompiler, loop_name : String, params : Array(String),
                                         inits : Array(Node), body : Array(Node), dst : Int32, tail : Bool) : Bool
      shape = detect_counted_loop_shape(loop_name, params, body)
      return false unless shape

      fc.push_scope
      mark = fc.next_reg
      init_regs = inits.map { |init| r = fc.alloc_reg; compile_expr(fc, init, r, false); r }
      fc.reclaim_to(mark)
      param_regs = params.map_with_index do |param, i|
        reg = fc.declare_local(param)
        fc.emit(Op::Move, reg, init_regs[i]) unless reg == init_regs[i]
        reg
      end

      emit_counted_loop(fc, params, param_regs, shape, Op::ForLoop, shape.step)
      compile_expr(fc, shape.base_branch, dst, tail)
      fc.pop_scope
      true
    end

    # Extends the same recognized shape (detect_counted_loop_shape) to an ordinary
    # self-recursive `(define (f params...) body)` — unlike a let-loop/do, `f`'s own name
    # is a mutable GLOBAL, so lowering straight to registers the same way would silently
    # stop honoring a mid-loop `(set! f ...)`/re-`define`. Two extra hard requirements on
    # top of the base shape make this safe: the step must be exactly +-1
    # (ForLoopGuardedInc/Dec only have room for a global reference by dropping ForLoop's
    # general step operand — see opcode.cr's own doc comment), and `name` must resolve to
    # :global from THIS function's own scope (not shadowed by a same-named param/local/
    # upvalue) — otherwise the recursive call wouldn't even compile to CallGlobal to
    # begin with. `fc` here is already the function's OWN FunctionCompiler (compile_lambda
    # has already pushed its scope and declared `params` as fc's own registers 0..), so —
    # unlike the let-loop/do path — there's no inits/Move-in step at all: the loop's
    # "initial values" are simply the function's own incoming arguments, already exactly
    # where they need to be.
    #
    # When recognized: the counted loop still runs entirely in registers, but every
    # iteration re-checks (by pointer identity, not eqv?/equal?) that the global is still
    # bound to the exact closure that's running, and deopts the instant it isn't — falls
    # through to a REAL, ordinary (unfused) compilation of the original `if`, exactly what
    # would have run without this optimization at all (see opcode.cr's ForLoopGuardedInc/
    # Dec and TestGlobalIdentity doc comments for the full mechanism).
    private def try_compile_global_counted_loop(fc : FunctionCompiler, name : String, params : Array(String),
                                                body : Array(Node), tail : Bool) : Bool
      return false unless tail
      shape = detect_counted_loop_shape(name, params, body)
      return false unless shape
      return false unless shape.step == 1 || shape.step == -1
      kind, _ = resolve_variable(fc, name)
      return false unless kind == :global

      param_regs = params.map { |param| fc.resolve_local(param) || raise "try_compile_global_counted_loop: param '#{param}' isn't a declared local" }
      loop_op = shape.step > 0 ? Op::ForLoopGuardedInc : Op::ForLoopGuardedDec
      name_const = fc.chunk.add_const(SchemeSym.of(name))
      emit_counted_loop(fc, params, param_regs, shape, loop_op, name_const)

      deopt_ip = fc.emit(Op::TestGlobalIdentity, name_const, 0)
      dst = fc.alloc_reg
      compile_expr(fc, shape.base_branch, dst, tail)
      # Deopt block — reachable only via TestGlobalIdentity's forward jump, the instant
      # the global's been reassigned mid-loop. Simply the ordinary, unfused compilation
      # of the whole original `if`, using the SAME param_regs (already holding exactly
      # what the next recursive call's arguments would be) — re-testing the base case
      # fresh, or tail-calling whatever `name` is bound to NOW if it's still recursing.
      fc.chunk.patch_jump_to_here(deopt_ip)
      compile_expr(fc, body[0], dst, tail)
      true
    end

    # The recognized shape of a "general" (non-counted) self-tail-recursive
    # loop (see try_compile_general_loop below): like CountedLoopShape, but
    # for a named-let/do whose recursion isn't a simple numeric counter
    # (e.g. it walks a list via `(cdr ...)`, not incrementing/decrementing
    # toward a limit) — `test`/`recurse_in_conseq` are enough to replay
    # compile_if's own then/else derivation at emission time (see
    # emit_general_loop), since termination isn't provable in general here
    # the way it is for a counted loop, so there's no ForPrep/ForLoop-style
    # fused range check to set up — just an ordinary per-iteration test.
    private record GeneralLoopShape,
      test : Node,
      recurse_in_conseq : Bool,
      split : CountedLoopCall,
      base_branch : Node

    # Tries to recognize `(let loop ((p init)...) (if test recurse-branch
    # base-branch))` (either branch order) as a "general" self-tail-
    # recursive loop: NOT a numeric counted loop (try_compile_counted_loop
    # already tried and failed, or this wouldn't be reached — see
    # compile_named_let/compile_do's own ordering), but still provably
    # non-escaping the exact same way a counted loop is — `loop_name`
    # referenced nowhere but the one recognized tail call, no lambda/case-
    # lambda literal anywhere in the body (contains_lambda?) — so it's
    # still safe to lower to plain mutable registers instead of allocating
    # a real Closure every time the enclosing function runs. Returns nil —
    # the caller's cue to fall back to its own ordinary (closure-based)
    # path — the moment any condition fails, same discipline as
    # detect_counted_loop_shape.
    # ameba:disable Metrics/CyclomaticComplexity
    private def detect_general_loop_shape(loop_name : String, params : Array(String), body : Array(Node)) : GeneralLoopShape?
      return nil unless body.size == 1 && body[0].is_a?(IfNode)
      if_node = body[0].as(IfNode)
      alt : Node = if_node.alt || LiteralNode.new(NIL)

      test, inverted = peel_not(if_node.test)
      then_branch = inverted ? alt : if_node.conseq
      else_branch = inverted ? if_node.conseq : alt

      return nil if contains_lambda?(test) || references_name?(test, loop_name)

      recurse_in_conseq, split, base_branch =
        if s = split_tail_self_call(then_branch, loop_name, params.size)
          {true, s, else_branch}
        elsif s = split_tail_self_call(else_branch, loop_name, params.size)
          {false, s, then_branch}
        else
          return nil
        end

      return nil if contains_lambda?(base_branch) || references_name?(base_branch, loop_name)
      split.prefix.each do |stmt|
        return nil if contains_lambda?(stmt) || references_name?(stmt, loop_name)
      end
      split.call.args.each do |arg|
        return nil if contains_lambda?(arg) || references_name?(arg, loop_name)
      end

      GeneralLoopShape.new(test, recurse_in_conseq, split, base_branch)
    end

    # Lowers a recognized GeneralLoopShape to plain mutable registers plus
    # an ordinary per-iteration test-and-branch (no ForPrep/ForLoop — there's
    # no numeric range to fuse into one instruction, just a ordinary test
    # each time round, same as compile_if's own generic path) and a
    # backward Op::Jmp closing the loop — mirrors emit_counted_loop's own
    # prefix/needs_temp/direct simultaneous-rebind handling for the
    # loop-carried parameters exactly, generalized from "counter + one
    # accumulator" to N arbitrary loop-carried values (there's no
    # "counter" here at all — every param is just an ordinary accumulator).
    # Unlike emit_counted_loop (whose caller compiles the base branch
    # separately afterward, since ForLoop's own fallthrough-on-exit makes
    # that always the next thing to compile), this compiles the base
    # branch itself, in whichever position (before/after the recurse body)
    # the source's own branch order puts it — the two control-flow shapes
    # aren't interchangeable the way ForLoop's single fallthrough is.
    private def emit_general_loop(fc : FunctionCompiler, params : Array(String), param_regs : Array(Int32),
                                  shape : GeneralLoopShape, dst : Int32, tail : Bool) : Nil
      loop_start = fc.chunk.instructions.size

      jmp_false = compile_fused_test(fc, shape.test, "if") || begin
        mark = fc.next_reg
        test_reg = fc.alloc_reg
        compile_expr(fc, shape.test, test_reg, false)
        fc.reclaim_to(mark)
        jmp = fc.emit(Op::TestFalse, test_reg, 0)
        fc.chunk.tag_sample(jmp, "if")
        jmp
      end

      emit_recurse_step = -> do
        shape.split.prefix.each do |stmt|
          mark = fc.next_reg
          discard = fc.alloc_reg
          compile_expr(fc, stmt, discard, false)
          fc.reclaim_to(mark)
        end

        mark2 = fc.next_reg
        all = (0...params.size).to_a
        needs_temp = all.select do |i|
          all.any? { |j| j != i && references_name?(shape.split.call.args[j], params[i]) }
        end
        direct = all - needs_temp
        temp_pairs = needs_temp.map { |i| r = fc.alloc_reg; compile_expr(fc, shape.split.call.args[i], r, false); {i, r} }
        direct.each { |i| compile_expr(fc, shape.split.call.args[i], param_regs[i], false) }
        temp_pairs.each { |i, reg| fc.emit(Op::Move, param_regs[i], reg) unless param_regs[i] == reg }
        fc.reclaim_to(mark2)

        # A backward jump — patch_jump_to_here only ever computes a FORWARD
        # target (@instructions.size at call time), so this instruction is
        # built directly instead, same technique emit_counted_loop's own
        # loop_ip already uses for its own backward-jumping terminal op.
        back_ip = fc.emit(Op::Jmp, 0, 0)
        fc.chunk.instructions[back_ip] = Instruction.new(Op::Jmp, 0, loop_start - (back_ip + 1), 0, 0)
      end

      # The recurse body always ends in an unconditional backward jump, so
      # it never falls through — unlike compile_if's own conseq, it never
      # needs its own jmp-to-end. The base branch is the only path that can
      # ever fall through past this whole construct, so it's the only one
      # that (when not in tail position) needs one.
      if shape.recurse_in_conseq
        emit_recurse_step.call
        fc.chunk.patch_jump_to_here(jmp_false)
        compile_expr(fc, shape.base_branch, dst, tail)
      else
        compile_expr(fc, shape.base_branch, dst, tail)
        jmp_end = fc.emit(Op::Jmp, 0, 0) unless tail
        fc.chunk.patch_jump_to_here(jmp_false)
        emit_recurse_step.call
        fc.chunk.patch_jump_to_here(jmp_end) if jmp_end
      end
    end

    # The recognized shape of a "general" loop whose body is a `cond`
    # rather than a plain `if` (see detect_general_cond_loop_shape below)
    # — e.g. hashtable-test's own `scan`: `(cond (guard1 exit1) (guard2
    # exit2) (else (scan (cdr entries))))`. Scoped narrowly to the common
    # idiom this actually targets, not general if/cond-chain peeling: only
    # the LAST clause may recurse (either unconditionally, an `else`, or
    # with its own real test — `recurse_test`, nil for the `else` case),
    # and every EARLIER clause must be an ordinary, non-recursive,
    # lambda-free guard (`earlier_clauses`, compiled via the exact same
    # compile_cond_result plain `cond` clauses already use). A recursive
    # clause buried in the MIDDLE of a cond, or a nested if/cond a level
    # deeper than this, simply isn't recognized — falls back to the
    # ordinary closure-based path, same as any other shape this recognizer
    # declines.
    private record GeneralCondLoopShape,
      earlier_clauses : Array(CondClause),
      recurse_test : Node?,
      split : CountedLoopCall

    private def cond_clause_safe_for_loop?(clause : CondClause, loop_name : String) : Bool
      return false if clause.throw_msg
      if t = clause.test
        return false if contains_lambda?(t) || references_name?(t, loop_name)
      end
      if a = clause.arrow
        return false if contains_lambda?(a) || references_name?(a, loop_name)
      end
      clause.body.each do |stmt|
        return false if contains_lambda?(stmt) || references_name?(stmt, loop_name)
      end
      true
    end

    # ameba:disable Metrics/CyclomaticComplexity
    private def detect_general_cond_loop_shape(loop_name : String, params : Array(String), body : Array(Node)) : GeneralCondLoopShape?
      return nil unless body.size == 1 && body[0].is_a?(CondNode)
      node = body[0].as(CondNode)
      return nil if node.clauses.empty?
      last = node.clauses.last
      return nil if last.arrow || last.throw_msg || last.body.empty?
      # An earlier `else` would make the final (possibly-recursive) clause
      # unreachable dead code — reject rather than risk silently dropping
      # the recursion (shouldn't normally parse this way anyway).
      earlier = node.clauses[0...-1]
      return nil if earlier.any? { |clause| clause.test.nil? }

      last_branch : Node = last.body.size == 1 ? last.body[0] : BeginNode.new(last.body)
      return nil unless split = split_tail_self_call(last_branch, loop_name, params.size)

      if t = last.test
        return nil if contains_lambda?(t) || references_name?(t, loop_name)
      end
      split.prefix.each do |stmt|
        return nil if contains_lambda?(stmt) || references_name?(stmt, loop_name)
      end
      split.call.args.each do |arg|
        return nil if contains_lambda?(arg) || references_name?(arg, loop_name)
      end
      return nil unless earlier.all? { |clause| cond_clause_safe_for_loop?(clause, loop_name) }

      GeneralCondLoopShape.new(earlier, last.test, split)
    end

    # Lowers a recognized GeneralCondLoopShape the same way emit_general_
    # loop does for a plain `if` — plain mutable registers, an ordinary
    # per-iteration test chain (reusing compile_cond_result for each
    # earlier, non-recursive clause, exactly like an ordinary `cond`
    # compiles), and a backward Op::Jmp closing the loop. Earlier clauses
    # that don't match jump past BOTH the remaining earlier clauses AND
    # the recursive clause's own handling (`end_jumps`, patched once at
    # the very end) — mirrors compile_cond_clauses' own per-clause
    # jmp_false/jmp_end structure, just reimplemented as an explicit loop
    # here rather than reusing that method's own recursive-index calling
    # convention (whose "ran out of clauses" base case is hardcoded to
    # emit NIL, not "fall through to the recursive clause").
    private def emit_general_cond_loop(fc : FunctionCompiler, params : Array(String), param_regs : Array(Int32),
                                       shape : GeneralCondLoopShape, dst : Int32, tail : Bool) : Nil
      loop_start = fc.chunk.instructions.size
      end_jumps = [] of Int32

      shape.earlier_clauses.each do |clause|
        # guaranteed by detect_general_cond_loop_shape (no earlier else)
        test = clause.test || raise "emit_general_cond_loop: earlier clause has no test (should've been rejected as an else)"
        mark = fc.next_reg
        test_reg = fc.alloc_reg
        compile_expr(fc, test, test_reg, false)
        fc.reclaim_to(mark)
        jmp_false = fc.emit(Op::TestFalse, test_reg, 0)
        fc.chunk.tag_sample(jmp_false, "cond")
        compile_cond_result(fc, clause, test_reg, dst, tail)
        end_jumps << fc.emit(Op::Jmp, 0, 0) unless tail
        fc.chunk.patch_jump_to_here(jmp_false)
      end

      emit_recurse_step = -> do
        shape.split.prefix.each do |stmt|
          mark = fc.next_reg
          discard = fc.alloc_reg
          compile_expr(fc, stmt, discard, false)
          fc.reclaim_to(mark)
        end

        mark2 = fc.next_reg
        all = (0...params.size).to_a
        needs_temp = all.select do |i|
          all.any? { |j| j != i && references_name?(shape.split.call.args[j], params[i]) }
        end
        direct = all - needs_temp
        temp_pairs = needs_temp.map { |i| r = fc.alloc_reg; compile_expr(fc, shape.split.call.args[i], r, false); {i, r} }
        direct.each { |i| compile_expr(fc, shape.split.call.args[i], param_regs[i], false) }
        temp_pairs.each { |i, reg| fc.emit(Op::Move, param_regs[i], reg) unless param_regs[i] == reg }
        fc.reclaim_to(mark2)

        back_ip = fc.emit(Op::Jmp, 0, 0)
        fc.chunk.instructions[back_ip] = Instruction.new(Op::Jmp, 0, loop_start - (back_ip + 1), 0, 0)
      end

      if test = shape.recurse_test
        # The final clause has a real test, not a bare `else` — same
        # "no cond clause matched" semantics as ordinary cond: NIL.
        mark = fc.next_reg
        test_reg = fc.alloc_reg
        compile_expr(fc, test, test_reg, false)
        fc.reclaim_to(mark)
        jmp_false = fc.emit(Op::TestFalse, test_reg, 0)
        emit_recurse_step.call
        fc.chunk.patch_jump_to_here(jmp_false)
        emit_nil(fc, dst)
        fc.emit(Op::Return, dst) if tail
      else
        emit_recurse_step.call
      end

      end_jumps.each { |j| fc.chunk.patch_jump_to_here(j) }
    end

    # Recognizes and lowers a let-loop/do's self-tail-recursive loop to
    # plain mutable registers (no per-call Closure allocation, no per-
    # iteration Call/TailCall) when it's NOT a numeric counted loop (see
    # try_compile_counted_loop, always tried first — this is strictly the
    # fallback for a shape that recognizer can't fuse into ForPrep/ForLoop,
    # e.g. a named-let that recurses by walking a list via `(cdr ...)`
    # rather than incrementing/decrementing a counter toward a limit).
    # Tries the plain-`if` shape first, then the `cond` shape (see
    # detect_general_cond_loop_shape). Returns false — emitting NOTHING,
    # safe to retry via the ordinary compile_lambda+Call/TailCall path —
    # the moment NEITHER recognizer matches.
    private def try_compile_general_loop(fc : FunctionCompiler, loop_name : String, params : Array(String),
                                         inits : Array(Node), body : Array(Node), dst : Int32, tail : Bool) : Bool
      if_shape = detect_general_loop_shape(loop_name, params, body)
      cond_shape = detect_general_cond_loop_shape(loop_name, params, body) unless if_shape
      return false unless if_shape || cond_shape

      fc.push_scope
      mark = fc.next_reg
      init_regs = inits.map { |init| r = fc.alloc_reg; compile_expr(fc, init, r, false); r }
      fc.reclaim_to(mark)
      param_regs = params.map_with_index do |param, i|
        reg = fc.declare_local(param)
        fc.emit(Op::Move, reg, init_regs[i]) unless reg == init_regs[i]
        reg
      end

      if if_shape
        emit_general_loop(fc, params, param_regs, if_shape, dst, tail)
      elsif cond_shape
        emit_general_cond_loop(fc, params, param_regs, cond_shape, dst, tail)
      end
      fc.pop_scope
      true
    end

    private def compile_named_let(fc : FunctionCompiler, node : NamedLetNode, dst : Int32, tail : Bool) : Nil
      return if try_compile_counted_loop(fc, node.loop_name, node.params, node.inits, node.body, dst, tail)
      return if try_compile_general_loop(fc, node.loop_name, node.params, node.inits, node.body, dst, tail)
      fc.push_scope
      loop_reg = fc.declare_local(node.loop_name)
      compile_lambda(fc, node.params, nil, node.body, node.loop_name, loop_reg)
      mark = fc.next_reg
      # call_base must be allocated BEFORE the arg registers so they land
      # contiguously at call_base+1.. via ordinary alloc_reg calls (matching
      # compile_app) — allocating call_base afterward, once, would leave the
      # shifted arg-target registers never actually reserved.
      call_base = fc.alloc_reg
      fc.emit(Op::Move, call_base, loop_reg) unless call_base == loop_reg
      arg_regs = node.inits.map { fc.alloc_reg }
      node.inits.each_with_index { |init, i| compile_expr(fc, init, arg_regs[i], false) }
      if tail
        fc.emit(Op::TailCall, call_base, node.inits.size)
      else
        fc.emit(Op::Call, call_base, node.inits.size, dst)
      end
      fc.reclaim_to(mark)
      fc.pop_scope
    end

    # (do ((var init step)...) (test result...) command...) desugars, at
    # compile time, into exactly the named-let loop it's semantically
    # equivalent to:
    #   (let do-loop ((var init)...)
    #     (if test (begin result...) (begin command... (do-loop step...))))
    # — reusing compile_lambda/compile_if/compile_seq_tail/compile_app
    # directly on synthesized Nodes rather than emitting new bytecode logic
    # from scratch. A nil step means "unchanged", i.e. the arg node is just
    # a fresh read of the current value (VarRefNode(name)). The loop name is
    # gensym'd (not a valid Scheme identifier prefix) so it can never
    # collide with a real `var`.
    private def compile_do(fc : FunctionCompiler, node : DoNode, dst : Int32, tail : Bool) : Nil
      loop_name = "%do-loop-#{@loop_counter += 1}"
      dummy_src = Cons.new(NIL, NIL)
      step_args = node.names.map_with_index do |name, i|
        node.steps[i] || VarRefNode.new(name)
      end.map(&.as(Node))
      step_call = AppNode.new(VarRefNode.new(loop_name), step_args, dummy_src)
      loop_body = IfNode.new(node.test, BeginNode.new(node.results), BeginNode.new(node.commands + [step_call.as(Node)]))
      return if try_compile_counted_loop(fc, loop_name, node.names, node.inits, [loop_body.as(Node)], dst, tail)
      return if try_compile_general_loop(fc, loop_name, node.names, node.inits, [loop_body.as(Node)], dst, tail)

      fc.push_scope
      loop_reg = fc.declare_local(loop_name)
      compile_lambda(fc, node.names, nil, [loop_body.as(Node)], loop_name, loop_reg)
      mark = fc.next_reg
      call_base = fc.alloc_reg
      fc.emit(Op::Move, call_base, loop_reg) unless call_base == loop_reg
      arg_regs = node.inits.map { fc.alloc_reg }
      node.inits.each_with_index { |init, i| compile_expr(fc, init, arg_regs[i], false) }
      if tail
        fc.emit(Op::TailCall, call_base, node.inits.size)
      else
        fc.emit(Op::Call, call_base, node.inits.size, dst)
      end
      fc.reclaim_to(mark)
      fc.pop_scope
    end

    # (cond clause...) — walks clauses in order; the first whose test is
    # true (or an `else`) supplies the result, which the R7RS clause forms
    # decide (see compile_cond_result). No match evaluates to NIL. A
    # clause's own throw_msg (a malformed clause the analyzer deferred to
    # eval time) unconditionally raises the instant it's REACHED — it must
    # not even evaluate a test.
    private def compile_cond_clauses(fc : FunctionCompiler, clauses : Array(CondClause), index : Int32, dst : Int32, tail : Bool) : Nil
      if index >= clauses.size
        emit_nil(fc, dst)
        fc.emit(Op::Return, dst) if tail
        return
      end
      clause = clauses[index]
      if msg = clause.throw_msg
        fc.emit(Op::Throw, fc.chunk.add_const(SchemeStr.new(msg)))
        return
      end
      test = clause.test
      if test.nil? # else — always matches, tv is NIL
        compile_cond_result(fc, clause, nil, dst, tail)
        return
      end
      mark = fc.next_reg
      test_reg = fc.alloc_reg
      compile_expr(fc, test, test_reg, false)
      jmp_false = fc.emit(Op::TestFalse, test_reg, 0)
      fc.chunk.tag_sample(jmp_false, "cond")
      compile_cond_result(fc, clause, test_reg, dst, tail)
      fc.reclaim_to(mark)
      if tail
        fc.chunk.patch_jump_to_here(jmp_false)
        compile_cond_clauses(fc, clauses, index + 1, dst, tail)
      else
        jmp_end = fc.emit(Op::Jmp, 0, 0)
        fc.chunk.patch_jump_to_here(jmp_false)
        compile_cond_clauses(fc, clauses, index + 1, dst, tail)
        fc.chunk.patch_jump_to_here(jmp_end)
      end
    end

    # `test_reg` holds the already-computed test value (tv) — nil only for
    # an `else` clause, where tv is NIL, so a bodyless else falls through to
    # the same "bare value" path below and correctly yields NIL rather than
    # needing a separate case.
    private def compile_cond_result(fc : FunctionCompiler, clause : CondClause, test_reg : Int32?, dst : Int32, tail : Bool) : Nil
      if arrow = clause.arrow
        mark = fc.next_reg
        callee_reg = fc.alloc_reg
        compile_expr(fc, arrow, callee_reg, false)
        arg_reg = fc.alloc_reg
        if test_reg
          fc.emit(Op::Move, arg_reg, test_reg) unless arg_reg == test_reg
        else
          emit_nil(fc, arg_reg)
        end
        if tail
          fc.emit(Op::TailCall, callee_reg, 1)
        else
          fc.emit(Op::Call, callee_reg, 1, dst)
        end
        fc.reclaim_to(mark)
      elsif clause.body.empty?
        if test_reg
          fc.emit(Op::Move, dst, test_reg) unless dst == test_reg
        else
          emit_nil(fc, dst)
        end
        fc.emit(Op::Return, dst) if tail
      else
        compile_seq_tail(fc, clause.body, dst, tail)
      end
    end

    # (case key clause...) — the key is evaluated ONCE, then matched against
    # each clause's datums via eqv? (Op::CaseMatch). Unlike cond, a bodyless
    # clause evaluates to NIL, not the key, and `=>` applies the arrow
    # procedure to the KEY, not a match boolean.
    private def compile_case(fc : FunctionCompiler, node : CaseNode, dst : Int32, tail : Bool) : Nil
      mark = fc.next_reg
      key_reg = fc.alloc_reg
      compile_expr(fc, node.key, key_reg, false)
      if hashable_case?(node.clauses)
        compile_case_hash_dispatch(fc, node.clauses, key_reg, dst, tail)
      else
        compile_case_clauses(fc, node.clauses, 0, key_reg, dst, tail)
      end
      fc.reclaim_to(mark)
    end

    # Below what total-datum-count a case form's linear CaseMatch scan is
    # already fast enough that building a Hash isn't worth it.
    CASE_DISPATCH_MIN_DATUMS = 8

    # `datum`'s normalized Op::CaseDispatch key, or nil if its type can't
    # safely hash-dispatch — restricted to the eqv?-comparable types whose
    # equality is a cheap, allocation-free structural comparison (mirrors
    # Creme.scheme_eqv?'s own type dispatch in helpers.cr): SchemeInt,
    # SchemeChar, SchemeSym, SchemeBool, SchemeNil. Deliberately excluded:
    # SchemeFloat (eqv? distinguishes 0.0/-0.0 by bit pattern — hashable in
    # principle, but not worth the complexity for a datum type that's nearly
    # never used in case clauses), SchemeRational, and everything falling to
    # scheme_eqv?'s generic Reference#same? identity fallback (strings/
    # pairs/vectors as datums — legal but vanishingly rare). Any of those
    # appearing anywhere makes the whole case form fall back to the linear
    # CaseMatch path via hashable_case? below.
    private def hashable_case_key(datum : SchemeValue) : CaseDispatchKey?
      case datum
      when SchemeInt  then CaseDispatchKey.for_int(datum.value)
      when SchemeChar then CaseDispatchKey.for_char(datum.value)
      when SchemeSym  then CaseDispatchKey.for_sym(datum.name)
      when SchemeBool then CaseDispatchKey.for_bool(datum.value?)
      when SchemeNil  then CaseDispatchKey::NIL
      else                 nil
      end
    end

    # Whether `clauses` is eligible for the O(1) Op::CaseDispatch path
    # instead of the O(clause count) CaseMatch/TestFalse chain. See
    # hashable_case_key's doc comment for which datum types qualify; beyond
    # that, this also requires: no malformed clause (a throw_msg clause is
    # rare enough it isn't worth modeling in the fast path — bail to linear,
    # which already handles it via Op::Throw), and at most one `else`, which
    # if present must be LAST — compile_case_clauses processes clauses in
    # list order with no requirement else be last, so an else appearing
    # earlier short-circuits later clauses; hash dispatch can't reproduce
    # arbitrary clause-order short-circuiting, so any other placement bails
    # to the linear path too.
    private def hashable_case?(clauses : Array(CaseClause)) : Bool
      total_datums = 0
      clauses.each_with_index do |clause, index|
        return false if clause.throw_msg
        if clause.els?
          return false if index != clauses.size - 1
          next
        end
        datums = clause.datums
        return false if datums.nil? || datums.empty?
        return false unless datums.all? { |datum| hashable_case_key(datum) }
        total_datums += datums.size
      end
      total_datums >= CASE_DISPATCH_MIN_DATUMS
    end

    # Builds one Op::CaseDispatch + its CaseDispatchTable instead of the
    # CaseMatch/TestFalse chain compile_case_clauses emits — same clause
    # bodies (via the unchanged compile_case_result), just entered by a
    # direct O(1) jump instead of a linear match-then-branch per clause.
    private def compile_case_hash_dispatch(fc : FunctionCompiler, clauses : Array(CaseClause), key_reg : Int32, dst : Int32, tail : Bool) : Nil
      key_to_clause = {} of CaseDispatchKey => Int32
      els_index = nil
      clauses.each_with_index do |clause, index|
        if clause.els?
          els_index = index
          next
        end
        (clause.datums || [] of SchemeValue).each do |datum|
          next unless key = hashable_case_key(datum)
          key_to_clause[key] = index unless key_to_clause.has_key?(key)
        end
      end

      table_id = fc.chunk.add_case_dispatch_table
      fc.emit(Op::CaseDispatch, key_reg, table_id)
      fc.chunk.tag_sample(fc.chunk.instructions.size - 1, "case")

      clause_starts = {} of Int32 => Int32
      jmp_ends = [] of Int32
      clauses.each_with_index do |clause, index|
        clause_starts[index] = fc.chunk.instructions.size
        compile_case_result(fc, clause, key_reg, dst, tail)
        jmp_ends << fc.emit(Op::Jmp, 0, 0) unless tail
      end

      default_target = if els = els_index
                         clause_starts[els]
                       else
                         nil_start = fc.chunk.instructions.size
                         emit_nil(fc, dst)
                         fc.emit(Op::Return, dst) if tail
                         nil_start
                       end
      jmp_ends.each { |j| fc.chunk.patch_jump_to_here(j) }

      table = fc.chunk.case_dispatch_tables[table_id]
      key_to_clause.each { |key, index| table.targets[key] = clause_starts[index] }
      table.default = default_target
    end

    private def compile_case_clauses(fc : FunctionCompiler, clauses : Array(CaseClause), index : Int32, key_reg : Int32, dst : Int32, tail : Bool) : Nil
      if index >= clauses.size
        emit_nil(fc, dst)
        fc.emit(Op::Return, dst) if tail
        return
      end
      clause = clauses[index]
      if msg = clause.throw_msg
        fc.emit(Op::Throw, fc.chunk.add_const(SchemeStr.new(msg)))
        return
      end
      if clause.els?
        compile_case_result(fc, clause, key_reg, dst, tail)
        return
      end
      mark = fc.next_reg
      match_reg = fc.alloc_reg
      datums_const = fc.chunk.add_const(SchemeVector.new((clause.datums || [] of SchemeValue).dup))
      fc.emit(Op::CaseMatch, match_reg, key_reg, datums_const)
      jmp_false = fc.emit(Op::TestFalse, match_reg, 0)
      fc.chunk.tag_sample(jmp_false, "case")
      fc.reclaim_to(mark)
      compile_case_result(fc, clause, key_reg, dst, tail)
      if tail
        fc.chunk.patch_jump_to_here(jmp_false)
        compile_case_clauses(fc, clauses, index + 1, key_reg, dst, tail)
      else
        jmp_end = fc.emit(Op::Jmp, 0, 0)
        fc.chunk.patch_jump_to_here(jmp_false)
        compile_case_clauses(fc, clauses, index + 1, key_reg, dst, tail)
        fc.chunk.patch_jump_to_here(jmp_end)
      end
    end

    private def compile_case_result(fc : FunctionCompiler, clause : CaseClause, key_reg : Int32, dst : Int32, tail : Bool) : Nil
      if arrow = clause.arrow
        mark = fc.next_reg
        callee_reg = fc.alloc_reg
        compile_expr(fc, arrow, callee_reg, false)
        arg_reg = fc.alloc_reg
        fc.emit(Op::Move, arg_reg, key_reg) unless arg_reg == key_reg
        if tail
          fc.emit(Op::TailCall, callee_reg, 1)
        else
          fc.emit(Op::Call, callee_reg, 1, dst)
        end
        fc.reclaim_to(mark)
      elsif clause.body.empty?
        emit_nil(fc, dst)
        fc.emit(Op::Return, dst) if tail
      else
        compile_seq_tail(fc, clause.body, dst, tail)
      end
    end

    private def compile_lambda(fc : FunctionCompiler, params : Array(String), rest : String?, body : Array(Node),
                               name : String, dst : Int32) : Nil
      child = FunctionCompiler.new(fc, name)
      child.push_scope
      params.each { |param| child.declare_local(param) }
      rest_name = rest
      child.declare_local(rest_name) if rest_name
      child.chunk.param_count = params.size
      child.chunk.has_rest = !rest_name.nil?
      # A plain self-recursive `(define (f params...) body)` gets the same counted-loop
      # fusion a let-loop/do already would (see try_compile_global_counted_loop's own
      # doc comment) — tried first since, like try_compile_counted_loop, it either
      # lowers the whole body itself and returns true, or emits nothing and returns
      # false the instant any of its hard requirements fails, safe to fall back to the
      # ordinary compile_body path. Never even attempted for a rest-arg lambda — the
      # recognizer's arity-based self-call matching doesn't account for one.
      if rest_name || !try_compile_global_counted_loop(child, name, params, body, true)
        compile_body(child, body, tail: true)
      end
      append_return_sentinel(child)
      child.pop_scope
      proto_idx = fc.chunk.add_proto(child.chunk)
      fc.emit(Op::Closure, dst, proto_idx)
    end

    # (case-lambda (formals body...) ...) — each clause is compiled and
    # closed over exactly like an ordinary lambda (compile_lambda, reused
    # verbatim, so upvalue capture per clause is already correct), then the
    # resulting BytecodeClosures are bundled by MakeCaseClosure into one
    # BytecodeCaseClosure that select_clause dispatches on by argument count.
    private def compile_case_lambda(fc : FunctionCompiler, node : CaseLambdaNode, dst : Int32) : Nil
      mark = fc.next_reg
      first_reg = fc.next_reg
      node.clauses.each do |clause|
        reg = fc.alloc_reg
        compile_lambda(fc, clause.params, clause.rest, clause.body_nodes, clause.name, reg)
      end
      fc.emit(Op::MakeCaseClosure, dst, first_reg, node.clauses.size)
      fc.reclaim_to(mark)
    end

    # Evaluates a values-producer expression into a fresh register, then
    # unpacks it (Op::Destructure) into `binder.params.size` (+1 if there's
    # a rest param) freshly allocated temp registers — returned still "raw"
    # (not yet bound to declared local names), since define-values/
    # let-values/let*-values each decide differently WHERE those names end
    # up (global vs. local, one shared scope vs. sequential visibility).
    private def compile_values_destructure(fc : FunctionCompiler, params : Array(String), rest : String?, producer : Node) : Array(Int32)
      prod_reg = fc.alloc_reg
      compile_expr(fc, producer, prod_reg, false)
      count = params.size + (rest ? 1 : 0)
      dst_base = fc.next_reg
      count.times { fc.alloc_reg }
      fc.emit(Op::Destructure, prod_reg, dst_base, params.size, rest ? 1 : 0)
      Array.new(count) { |i| dst_base + i }
    end

    private def values_names(params : Array(String), rest : String?) : Array(String)
      rest ? params + [rest] : params
    end

    # (define-values (a b . rest) producer) — same global-vs-local-define
    # decision as plain `define` (see the DefineNode arm above).
    private def compile_define_values(fc : FunctionCompiler, node : DefineValuesNode, dst : Int32, tail : Bool) : Nil
      mark = fc.next_reg
      regs = compile_values_destructure(fc, node.params, node.rest, node.producer)
      at_toplevel = fc.scope.nil? && fc.is_toplevel?
      values_names(node.params, node.rest).each_with_index do |name, i|
        if at_toplevel
          compile_name_write(fc, name, regs[i], true)
        else
          # See compile_expr's DefineNode arm: reuse the register
          # pre_declare_internal_defines already reserved for this name
          # (so forward references resolve), rather than allocating a
          # second one — and never reclaim it below.
          target = fc.local_in_current_scope?(name) || fc.declare_local(name)
          fc.emit(Op::Move, target, regs[i]) unless target == regs[i]
        end
      end
      fc.reclaim_to(mark) if at_toplevel
      emit_nil(fc, dst)
      fc.emit(Op::Return, dst) if tail
    end

    # (let-values ((formals producer)...) body...) / let*-values (sequential
    # visibility of earlier binders' names to later producers). Non-
    # sequential producers must NOT see any of this form's own bindings —
    # mirrors compile_let's plain-`let` ordering: destructure every binder
    # first (against the outer scope), THEN push a scope and declare names.
    private def compile_let_values(fc : FunctionCompiler, node : LetValuesNode, dst : Int32, tail : Bool) : Nil
      outer_mark = fc.next_reg
      if node.sequential?
        fc.push_scope
        node.binders.each do |binder|
          regs = compile_values_destructure(fc, binder.params, binder.rest, binder.producer)
          values_names(binder.params, binder.rest).each_with_index do |name, i|
            target = fc.declare_local(name)
            fc.emit(Op::Move, target, regs[i]) unless target == regs[i]
          end
        end
      else
        bound = [] of {String, Int32}
        node.binders.each do |binder|
          regs = compile_values_destructure(fc, binder.params, binder.rest, binder.producer)
          values_names(binder.params, binder.rest).each_with_index { |name, i| bound << {name, regs[i]} }
        end
        fc.push_scope
        bound.each do |name_reg|
          name, reg = name_reg
          target = fc.declare_local(name)
          fc.emit(Op::Move, target, reg) unless target == reg
        end
      end
      compile_seq_tail(fc, node.body, dst, tail)
      fc.pop_scope
      fc.reclaim_to(outer_mark)
    end

    # (parameterize ((param val)...) body...). Never tail (the dynamic
    # extent's restore must run right after body), so body is always compiled
    # non-tail into its own temp register regardless of the caller's `tail`.
    # Params/newvals are evaluated into two contiguous register blocks so
    # Op::ParamPush can address them as (first_param_reg, first_newval_reg,
    # count).
    private def compile_parameterize(fc : FunctionCompiler, node : ParameterizeNode, dst : Int32, tail : Bool) : Nil
      mark = fc.next_reg
      param_reg0 = fc.next_reg
      node.bindings.each { |binding| r = fc.alloc_reg; compile_expr(fc, binding.param, r, false) }
      newval_reg0 = fc.next_reg
      node.bindings.each { |binding| r = fc.alloc_reg; compile_expr(fc, binding.value, r, false) }
      fc.emit(Op::ParamPush, param_reg0, newval_reg0, node.bindings.size)
      body_dst = fc.alloc_reg
      compile_seq_tail(fc, node.body, body_dst, false)
      fc.emit(Op::ParamPop)
      fc.emit(Op::Move, dst, body_dst) unless dst == body_dst
      fc.reclaim_to(mark)
      fc.emit(Op::Return, dst) if tail
    end

    # (guard (var clause...) body...). body is ALWAYS compiled non-tail: the
    # installed handler must not be invalidated by a TailCall repointing THIS
    # frame's chunk/ip to somewhere else while it's still in scope; see
    # PushHandler's doc comment. PushHandler's offset lands on the clause-checking code,
    # compiled by compile_guard_clauses — reached only if the VM's
    # handle_guarded_error jumps there; the normal (no error) path runs
    # PopHandler and jumps PAST the clause code entirely.
    private def compile_guard(fc : FunctionCompiler, node : GuardNode, dst : Int32, tail : Bool) : Nil
      mark = fc.next_reg
      condition_reg = fc.alloc_reg
      push_handler_instr = fc.emit(Op::PushHandler, condition_reg, 0)
      compile_seq_tail(fc, node.body, dst, false)
      fc.emit(Op::PopHandler)
      jmp_over_clauses = fc.emit(Op::Jmp, 0, 0)
      fc.chunk.patch_jump_to_here(push_handler_instr)
      fc.push_scope
      var_reg = fc.declare_local(node.var)
      fc.emit(Op::Move, var_reg, condition_reg) unless var_reg == condition_reg
      # Clause bodies run only AFTER the handler that protected `body` has
      # already been popped (handle_guarded_error pops it before jumping
      # here) — guard's own protection is over by this point, so a matched
      # clause CAN genuinely tail-call out if the enclosing guard form
      # itself is in tail position.
      compile_guard_clauses(fc, node.clauses, 0, dst, tail)
      fc.pop_scope
      fc.chunk.patch_jump_to_here(jmp_over_clauses)
      fc.reclaim_to(mark)
      fc.emit(Op::Return, dst) if tail
    end

    # Identical to compile_cond_clauses (same CondClause shape, same else/
    # arrow/bare-value/throw_msg semantics) except no match re-raises the
    # exception currently being handled instead of yielding NIL — guard
    # clauses that don't match must propagate to an outer handler.
    private def compile_guard_clauses(fc : FunctionCompiler, clauses : Array(CondClause), index : Int32, dst : Int32, tail : Bool) : Nil
      if index >= clauses.size
        fc.emit(Op::GuardReraise)
        return
      end
      clause = clauses[index]
      if msg = clause.throw_msg
        fc.emit(Op::Throw, fc.chunk.add_const(SchemeStr.new(msg)))
        return
      end
      test = clause.test
      if test.nil?
        compile_cond_result(fc, clause, nil, dst, tail)
        return
      end
      mark = fc.next_reg
      test_reg = fc.alloc_reg
      compile_expr(fc, test, test_reg, false)
      jmp_false = fc.emit(Op::TestFalse, test_reg, 0)
      compile_cond_result(fc, clause, test_reg, dst, tail)
      fc.reclaim_to(mark)
      if tail
        fc.chunk.patch_jump_to_here(jmp_false)
        compile_guard_clauses(fc, clauses, index + 1, dst, tail)
      else
        jmp_end = fc.emit(Op::Jmp, 0, 0)
        fc.chunk.patch_jump_to_here(jmp_false)
        compile_guard_clauses(fc, clauses, index + 1, dst, tail)
        fc.chunk.patch_jump_to_here(jmp_end)
      end
    end

    # (quasiquote template). Reuses the analyzer's own QQTemplate tree
    # (QQConst/QQHole/QQSpliceItem/QQList/QQVector — see ast.cr) verbatim as
    # compile-time data (stored in chunk.qq_templates, never serialized into
    # the const pool since only VM#build_qq's Crystal code ever reads it).
    # Every hole (QQHole and QQSpliceItem, which are the only two node kinds
    # requiring runtime evaluation) is compiled into its OWN register, in
    # the exact depth-first order compile_qq_holes and VM#build_qq both
    # walk the template — matching that order between compile time and run
    # time is what lets build_qq pull each hole's pre-evaluated value back
    # out correctly.
    private def compile_quasiquote(fc : FunctionCompiler, node : QuasiquoteNode, dst : Int32) : Nil
      mark = fc.next_reg
      hole_base = fc.next_reg
      compile_qq_holes(fc, node.template)
      template_idx = fc.chunk.add_qq_template(node.template)
      fc.emit(Op::Quasiquote, dst, template_idx, hole_base)
      fc.reclaim_to(mark)
    end

    private def compile_qq_holes(fc : FunctionCompiler, t : QQTemplate) : Nil
      case t
      when QQConst
        # nothing to compile — a literal fragment, kept verbatim
      when QQHole
        compile_expr(fc, t.node, fc.alloc_reg, false)
      when QQSpliceItem
        compile_expr(fc, t.node, fc.alloc_reg, false)
      when QQList
        t.items.each { |item| compile_qq_holes(fc, item) }
        compile_qq_holes(fc, t.tail)
      when QQVector
        t.items.each { |item| compile_qq_holes(fc, item) }
      end
    end

    # (delay expr) / (delay-force expr). Wraps a 0-arg closure (compiled
    # exactly like an ordinary lambda) in a SchemePromise — `force`
    # (modules/scheme/base.cr) already knows to `apply` this thunk closure
    # directly (see SchemePromise#thunk_closure).
    private def compile_delay(fc : FunctionCompiler, node : DelayNode, dst : Int32) : Nil
      mark = fc.next_reg
      closure_reg = fc.alloc_reg
      compile_lambda(fc, [] of String, nil, [node.thunk], "promise-thunk", closure_reg)
      fc.emit(Op::MakePromise, dst, closure_reg)
      fc.reclaim_to(mark)
    end

    # import/define-library/define-record-type/define-syntax/defmacro are
    # one-shot, cold-path forms that install bindings into an Env — since
    # this VM's local scopes are registers, not an Env, they're only
    # supported at the top level (where `env` is unambiguously
    # @interp.global, exactly like DefineNode's global path). The raw form
    # is preserved as a const (a Cons is already a SchemeValue) and handed
    # to the Interpreter's eval_* helper for that form — these forms are
    # never hot enough to be worth reimplementing against registers.
    private def compile_helper_form(fc : FunctionCompiler, node : HelperFormNode, dst : Int32) : Nil
      at_toplevel = fc.scope.nil? && fc.is_toplevel?
      unless at_toplevel
        case node.kind
        when HelperForm::DefineSyntax, HelperForm::Defmacro
          # A LOCAL define-syntax/defmacro's actual work (registering the
          # macro so later forms in this same lexical scope expand it) is
          # already fully done at analyze time, into the analyzer's own
          # compile-time MacroEnv (@analyzing_macros) — unlike a top-level
          # one, it never needs a live Env binding at all (analyze_cons
          # only consults the runtime env for TOP-LEVEL/imported macros).
          # So there's nothing left to run here.
          emit_nil(fc, dst)
          return
        when HelperForm::DefineRecordType
          names = Creme.record_type_names(node.form)
          if names && !names.empty?
            first_reg = fc.local_in_current_scope?(names[0]) || fc.declare_local(names[0])
            form_idx = fc.chunk.add_const(node.form)
            fc.emit(Op::HelperFormLocal, first_reg, form_idx, names.size)
            fc.emit(Op::Move, dst, first_reg) unless dst == first_reg
            return
          end
          raise SchemeRuntimeError.new("bytecode VM: define-record-type is malformed")
        else
          raise SchemeRuntimeError.new("bytecode VM: #{node.kind} is only supported at the top level, not inside a function body")
        end
      end
      kind = case node.kind
             in HelperForm::Import           then 0
             in HelperForm::DefineLibrary    then 1
             in HelperForm::DefineRecordType then 2
             in HelperForm::DefineSyntax     then 3
             in HelperForm::Defmacro         then 4
             end
      form_idx = fc.chunk.add_const(node.form)
      fc.emit(Op::HelperForm, dst, form_idx, kind)
    end

    # A side-effect-free node: evaluating it can never run arbitrary Scheme
    # code nor mutate any local, so its position in evaluation order relative
    # to a sibling doesn't matter — which is exactly what lets a sibling bare
    # local alias its own register instead of being staged through a Move
    # (see local_register_of? and its callers' suffix/all-leaves gates).
    #
    # The base cases are the pure reads: literals and variable references
    # (no computed-property/getter globals in this language). A PrimCallNode
    # is included recursively when all its arguments are themselves
    # side-effect-free: executing a fused prim op writes only its own dst
    # register (a fresh temp) and, for the mutating ops (vector-set! etc.),
    # a heap object — never a caller local's register — so the *only* way a
    # prim call could mutate a local L before a sibling reads it is via a
    # set!/call buried in one of its own arguments, which the recursion
    # rules out. (Cxr/Abs/arithmetic deopts merely raise or fall to the
    # numeric tower; they run no user code and mutate no register either.)
    private def leaf_node?(node : Node) : Bool
      case node
      when LiteralNode, VarRefNode, LocalRefNode, GlobalRefNode then true
      when PrimCallNode                                         then node.args.all? { |arg| leaf_node?(arg) }
      else                                                           false
      end
    end

    # Whether `node` (recursively, through every compound Node type in
    # ast.cr) contains a `lambda`/`case-lambda` literal anywhere — the
    # syntactic escape-safety condition a counted-loop lowering (see
    # compile_named_let/compile_do's fast-path recognizer) relies on: if no
    # closure is ever created inside a loop's body, nothing can capture a
    # per-iteration register binding, so it's safe to reuse plain mutable
    # registers across iterations instead of allocating a real closure each
    # time. Conservative on anything it can't inspect (HelperFormNode's raw
    # Cons form) — reports `true` (contains a lambda) so the recognizer
    # declines rather than risk lowering something unsafe.
    # ameba:disable Metrics/CyclomaticComplexity
    private def contains_lambda?(node : Node) : Bool
      case node
      when LambdaNode, CaseLambdaNode
        true
      when ThrowNode, LiteralNode, VarRefNode, LocalRefNode, GlobalRefNode
        false
      when IfNode
        contains_lambda?(node.test) || contains_lambda?(node.conseq) ||
          (node.alt.try { |alt| contains_lambda?(alt) } || false)
      when BeginNode
        node.body.any? { |child| contains_lambda?(child) }
      when DefineNode
        contains_lambda?(node.value)
      when LetNode, LetStarNode, LetrecNode
        # Plain let/let*/letrec create no closure of their own (no Op::Closure
        # is ever emitted for them — their body compiles directly inline into
        # the current function), so recursing through them is safe.
        node.inits.any? { |child| contains_lambda?(child) } || node.body.any? { |child| contains_lambda?(child) }
      when NamedLetNode, DoNode
        # Unlike plain let, these DO desugar into a real closure (compile_
        # named_let/compile_do both call compile_lambda for the loop
        # procedure) — treated the same as an explicit lambda literal, since
        # that's what they compile to. A nested countable loop inside this
        # one is deliberately out of scope for the counted-loop recognizer
        # (see its own doc comment) rather than something worth threading
        # escape-safety through.
        true
      when SetBangNode
        contains_lambda?(node.value)
      when WhenNode
        contains_lambda?(node.test) || node.body.any? { |child| contains_lambda?(child) }
      when AndNode, OrNode
        node.exprs.any? { |child| contains_lambda?(child) }
      when CondNode
        node.clauses.any? do |clause|
          (clause.test.try { |test| contains_lambda?(test) } || false) ||
            clause.body.any? { |child| contains_lambda?(child) } ||
            (clause.arrow.try { |arrow| contains_lambda?(arrow) } || false)
        end
      when CaseNode
        contains_lambda?(node.key) || node.clauses.any? do |clause|
          clause.body.any? { |child| contains_lambda?(child) } ||
            (clause.arrow.try { |arrow| contains_lambda?(arrow) } || false)
        end
      when PrimCallNode
        node.args.any? { |child| contains_lambda?(child) }
      when DefineValuesNode
        contains_lambda?(node.producer)
      when LetValuesNode
        node.binders.any? { |binder| contains_lambda?(binder.producer) } || node.body.any? { |child| contains_lambda?(child) }
      when QuasiquoteNode
        qq_contains_lambda?(node.template)
      when DelayNode
        contains_lambda?(node.thunk)
      when GuardNode
        node.clauses.any? do |clause|
          (clause.test.try { |test| contains_lambda?(test) } || false) ||
            clause.body.any? { |child| contains_lambda?(child) } ||
            (clause.arrow.try { |arrow| contains_lambda?(arrow) } || false)
        end || node.body.any? { |child| contains_lambda?(child) }
      when ParameterizeNode
        node.bindings.any? { |binding| contains_lambda?(binding.param) || contains_lambda?(binding.value) } ||
          node.body.any? { |child| contains_lambda?(child) }
      when AppNode
        contains_lambda?(node.callee) || node.args.any? { |child| contains_lambda?(child) }
      else
        # HelperFormNode (raw, uninterpreted Cons) or anything future — can't
        # prove it's lambda-free, so decline conservatively.
        true
      end
    end

    private def qq_contains_lambda?(template : QQTemplate) : Bool
      case template
      when QQConst      then false
      when QQHole       then contains_lambda?(template.node)
      when QQSpliceItem then contains_lambda?(template.node)
      when QQList       then template.items.any? { |item| qq_contains_lambda?(item) } || qq_contains_lambda?(template.tail)
      when QQVector     then template.items.any? { |item| qq_contains_lambda?(item) }
      else                   true
      end
    end

    # Whether `name` is referenced (read OR written — includes SetBangNode's
    # own target) anywhere in `node`, recursively through every compound Node
    # type. Used alongside contains_lambda? to prove a counted-loop's own
    # loop-name binding never escapes: with no lambda literal in the body
    # (contains_lambda? false), the only way `name` could still matter beyond
    # the one recognized tail self-call is an ordinary reference somewhere
    # else in the body — which this walks for directly. Conservative on
    # anything it can't inspect, same as contains_lambda?.
    # ameba:disable Metrics/CyclomaticComplexity
    private def references_name?(node : Node, name : String) : Bool
      case node
      when ThrowNode, LiteralNode
        false
      when VarRefNode
        node.name == name
      when LocalRefNode
        node.name == name
      when GlobalRefNode
        node.name == name
      when IfNode
        references_name?(node.test, name) || references_name?(node.conseq, name) ||
          (node.alt.try { |alt| references_name?(alt, name) } || false)
      when BeginNode
        node.body.any? { |child| references_name?(child, name) }
      when DefineNode
        references_name?(node.value, name)
      when LetNode, LetStarNode, LetrecNode
        node.inits.any? { |child| references_name?(child, name) } || node.body.any? { |child| references_name?(child, name) }
      when NamedLetNode
        node.inits.any? { |child| references_name?(child, name) } || node.body.any? { |child| references_name?(child, name) }
      when DoNode
        node.inits.any? { |child| references_name?(child, name) } ||
          node.steps.any? { |child| child.try { |step| references_name?(step, name) } || false } ||
          references_name?(node.test, name) ||
          node.results.any? { |child| references_name?(child, name) } ||
          node.commands.any? { |child| references_name?(child, name) }
      when SetBangNode
        node.name == name || references_name?(node.value, name)
      when WhenNode
        references_name?(node.test, name) || node.body.any? { |child| references_name?(child, name) }
      when AndNode, OrNode
        node.exprs.any? { |child| references_name?(child, name) }
      when CondNode
        node.clauses.any? do |clause|
          (clause.test.try { |test| references_name?(test, name) } || false) ||
            clause.body.any? { |child| references_name?(child, name) } ||
            (clause.arrow.try { |arrow| references_name?(arrow, name) } || false)
        end
      when CaseNode
        references_name?(node.key, name) || node.clauses.any? do |clause|
          clause.body.any? { |child| references_name?(child, name) } ||
            (clause.arrow.try { |arrow| references_name?(arrow, name) } || false)
        end
      when PrimCallNode
        node.args.any? { |child| references_name?(child, name) }
      when DefineValuesNode
        references_name?(node.producer, name)
      when LetValuesNode
        node.binders.any? { |binder| references_name?(binder.producer, name) } ||
          node.body.any? { |child| references_name?(child, name) }
      when QuasiquoteNode
        qq_references_name?(node.template, name)
      when DelayNode
        references_name?(node.thunk, name)
      when GuardNode
        node.clauses.any? do |clause|
          (clause.test.try { |test| references_name?(test, name) } || false) ||
            clause.body.any? { |child| references_name?(child, name) } ||
            (clause.arrow.try { |arrow| references_name?(arrow, name) } || false)
        end || node.body.any? { |child| references_name?(child, name) }
      when ParameterizeNode
        node.bindings.any? { |binding| references_name?(binding.param, name) || references_name?(binding.value, name) } ||
          node.body.any? { |child| references_name?(child, name) }
      when AppNode
        references_name?(node.callee, name) || node.args.any? { |child| references_name?(child, name) }
      else
        true
      end
    end

    private def qq_references_name?(template : QQTemplate, name : String) : Bool
      case template
      when QQConst      then false
      when QQHole       then references_name?(template.node, name)
      when QQSpliceItem then references_name?(template.node, name)
      when QQList       then template.items.any? { |item| qq_references_name?(item, name) } || qq_references_name?(template.tail, name)
      when QQVector     then template.items.any? { |item| qq_references_name?(item, name) }
      else                   true
      end
    end

    # If `node` is a bare local-variable read, its own register — reusable
    # directly as a prim-call operand with no Move, since exec_prim's fused
    # ops already take arbitrary non-contiguous register operands. Returns
    # nil for anything else (globals/upvalues still need GetGlobal/GetUpval
    # to materialize a value; there's no register to alias for those).
    private def local_register_of?(fc : FunctionCompiler, node : Node) : Int32?
      name = case node
             when VarRefNode    then node.name
             when LocalRefNode  then node.name
             when GlobalRefNode then node.name
             else                    return nil
             end
      kind, idx = resolve_variable(fc, name)
      kind == :local ? idx : nil
    end

    # True iff `node` (a leaf_node?, so only literals/var-refs/leaf prim
    # calls can appear) reads local register `reg` anywhere in its tree —
    # used by compile_tail_call_args_in_place to detect when an EARLIER
    # argument can't yet be written into its own target register because a
    # LATER argument still needs to read what's currently there.
    private def leaf_references_register?(fc : FunctionCompiler, node : Node, reg : Int32) : Bool
      case node
      when PrimCallNode
        node.args.any? { |arg| leaf_references_register?(fc, arg, reg) }
      when VarRefNode, LocalRefNode, GlobalRefNode
        local_register_of?(fc, node) == reg
      else
        false # LiteralNode — reads nothing
      end
    end

    # Compiles a TAIL call's arguments directly into registers 0..n-1 of the
    # current frame instead of the general path's floating anchor+1.. run —
    # safe here specifically because every argument is a leaf_node? (the
    # caller already checked), so none of them can create a closure that
    # captures one of these registers as an upvalue — the one way writing
    # into a live register early, before a later argument is compiled, could
    # observably differ from the general path's behavior.
    #
    # `callee_kind`/`callee_reg` is the fused callee's own {kind, register}
    # from bare_callee_source, when it reads one (:local/:upvalue) — nil for
    # :global, which is resolved via a cache/const, not a register. Returns
    # the register the emitted Call*/TailCall* op should actually read the
    # callee from — ordinarily just `callee_reg` unchanged, EXCEPT when it
    # falls inside this call's own 0..n-1 target range: that instruction
    # reads its callee register at ITS OWN execution time, i.e. strictly
    # AFTER every argument below has already been written — so unlike an
    # argument (read by the separate bind_args step that runs even later,
    # once the callee is already resolved), deferring an overwrite via the
    # settle pass does NOT protect it; the only fix is to copy the callee's
    # value out to a fresh, out-of-range register BEFORE writing any
    # argument, and have the op read from that copy instead (caught by
    # "captures each loop iteration's own value independently" in
    # bytecode_vm_spec.cr: `(f 100)` inside `(lambda (f) (f 100))` has `f`
    # at register 0 — the same register argument 0 would otherwise target).
    #
    # Each argument is compiled in original left-to-right order (preserving
    # evaluation order exactly like the general path) directly into its
    # target register `i`, UNLESS some LATER (not yet compiled) argument
    # still needs to read register `i`'s current value — in which case
    # argument `i` is parked in a scratch register instead, and only moved
    # into place in a final settle pass once every argument has been
    # evaluated (order-independent then, since a scratch register can never
    # alias a target register — see the next_reg bump below).
    private def compile_tail_call_args_in_place(fc : FunctionCompiler, args : Array(Node),
                                                callee_kind : Symbol, callee_reg : Int32?) : Int32?
      mark = fc.next_reg
      # Reserve the WHOLE 0..n-1 target range from being handed out as a
      # scratch register below, even if the current function has fewer
      # locals than `args.size` (e.g. a 0-local function tail-calling a
      # 3-arg function) — alloc_reg is reused here (rather than assigning
      # next_reg/num_registers directly) purely so chunk.num_registers stays
      # correctly in sync via its own existing bookkeeping.
      (args.size - fc.next_reg).times { fc.alloc_reg } if fc.next_reg < args.size
      # Only :local's operand is a register in THIS frame (comparable to/
      # movable from a target register) — :upvalue's is an index into
      # fc.chunk.upvalues (a different space entirely, read via GetUpval
      # from the ENCLOSING frame's own storage, never this frame's own
      # registers) and :global's is a const-pool index, so neither can ever
      # coincide with an argument's target register in the first place.
      safe_callee_reg = callee_reg
      if callee_kind == :local && (r = callee_reg) && r < args.size
        scratch = fc.alloc_reg
        fc.emit(Op::Move, scratch, r)
        safe_callee_reg = scratch
      end
      pending = [] of {Int32, Int32} # {scratch_reg, target_reg}
      args.each_with_index do |arg, i|
        if args[(i + 1)...args.size].any? { |later| leaf_references_register?(fc, later, i) }
          scratch = fc.alloc_reg
          compile_expr(fc, arg, scratch, false)
          pending << {scratch, i}
        else
          compile_expr(fc, arg, i, false)
        end
      end
      pending.each { |pair| fc.emit(Op::Move, pair[1], pair[0]) unless pair[0] == pair[1] }
      fc.reclaim_to(mark)
      safe_callee_reg
    end

    # If `arg` is a literal wrapping a SchemeInt that fits in Instruction's
    # Int32 operand fields, that raw value — else nil. Anything else (a
    # non-integer literal, or a literal integer too large for Int32) falls
    # back to the ordinary LoadK-then-register path.
    private def imm_operand?(arg : Node) : Int32?
      return nil unless arg.is_a?(LiteralNode)
      value = arg.value
      return nil unless value.is_a?(SchemeInt)
      value.value.to_i32
    rescue OverflowError
      nil
    end

    # The AddImm-family counterpart of a 2-arg arithmetic/comparison Op, or
    # nil for anything else (vector/string/bytevector/cons/not/null?/pair?
    # ops have no immediate-operand shape).
    private def imm_op_for(op : Op) : Op?
      case op
      when Op::Add   then Op::AddImm
      when Op::Sub   then Op::SubImm
      when Op::Mul   then Op::MulImm
      when Op::NumLt then Op::NumLtImm
      when Op::NumLe then Op::NumLeImm
      when Op::NumGt then Op::NumGtImm
      when Op::NumGe then Op::NumGeImm
      when Op::NumEq then Op::NumEqImm
      when Op::IsEq  then Op::IsEqImm
      else                nil
      end
    end

    # If `node` is a bare closed-over-variable read, its upvalue index —
    # the mirror image of local_register_of?, for a variable resolving to
    # :upvalue instead of :local. Used by both Up-family fusions below.
    private def up_operand?(fc : FunctionCompiler, node : Node) : Int32?
      name = case node
             when VarRefNode    then node.name
             when LocalRefNode  then node.name
             when GlobalRefNode then node.name
             else                    return nil
             end
      kind, idx = resolve_variable(fc, name)
      kind == :upvalue ? idx : nil
    end

    # The AddUp-family counterpart of a 2-arg arithmetic/comparison Op —
    # sources the 2nd operand from an upvalue instead of a register/
    # immediate. Same op set as imm_op_for, nil for anything else.
    private def up_op_for_2nd(op : Op) : Op?
      case op
      when Op::Add   then Op::AddUp
      when Op::Sub   then Op::SubUp
      when Op::Mul   then Op::MulUp
      when Op::NumLt then Op::NumLtUp
      when Op::NumLe then Op::NumLeUp
      when Op::NumGt then Op::NumGtUp
      when Op::NumGe then Op::NumGeUp
      when Op::NumEq then Op::NumEqUp
      when Op::IsEq  then Op::IsEqUp
      else                nil
      end
    end

    # The *Up counterpart of a vector/string/bytevector Op — sources the
    # 1st argument (the object) from an upvalue instead of a register. nil
    # for anything else (arithmetic/comparison/cons/not/null?/pair? ops
    # have no "object" argument in this sense — see up_op_for_2nd instead).
    private def up_op_for_1st(op : Op) : Op?
      case op
      when Op::VecRef then Op::VecRefUp
      when Op::VecSet then Op::VecSetUp
      when Op::VecLen then Op::VecLenUp
      when Op::StrRef then Op::StrRefUp
      when Op::StrSet then Op::StrSetUp
      when Op::BvRef  then Op::BvRefUp
      when Op::BvSet  then Op::BvSetUp
      else                 nil
      end
    end

    # The *RefImm/*SetImm counterpart of a vector/string/bytevector
    # index-taking Ref/Set op — see opcode.cr's VecRefImm/StrRefImm/
    # BvRefImm/VecSetImm/StrSetImm/BvSetImm doc. nil for anything else
    # (VecLen has no index argument to fuse a literal into at all).
    private def imm_index_ref_op_for(op : Op) : Op?
      case op
      when Op::VecRef then Op::VecRefImm
      when Op::StrRef then Op::StrRefImm
      when Op::BvRef  then Op::BvRefImm
      else                 nil
      end
    end

    private def imm_index_set_op_for(op : Op) : Op?
      case op
      when Op::VecSet then Op::VecSetImm
      when Op::StrSet then Op::StrSetImm
      when Op::BvSet  then Op::BvSetImm
      else                 nil
      end
    end

    # The Return-fused counterpart of a base 2-arg arithmetic/comparison Op
    # — see opcode.cr's AddReturn doc. nil for anything else (the Imm/Up/
    # vector-family shapes emit a plain trailing Return in tail position;
    # only the general 2-arg path fuses this way).
    private def return_op_for(op : Op) : Op?
      case op
      when Op::Add   then Op::AddReturn
      when Op::Sub   then Op::SubReturn
      when Op::Mul   then Op::MulReturn
      when Op::NumLt then Op::NumLtReturn
      when Op::NumLe then Op::NumLeReturn
      when Op::NumGt then Op::NumGtReturn
      when Op::NumGe then Op::NumGeReturn
      when Op::NumEq then Op::NumEqReturn
      when Op::IsEq  then Op::IsEqReturn
      else                nil
      end
    end

    # `tail`: true when this call is itself in tail position. Returns true
    # when the call was compiled as a Return-fused instruction (only the
    # general 2-arg path, and only for the base arithmetic/comparison ops
    # — see return_op_for) — the caller must NOT also emit a trailing
    # Return in that case. Returns false otherwise (every other shape),
    # in which case the caller still emits its own ordinary tail Return.
    # ameba:disable Metrics/CyclomaticComplexity
    private def compile_prim_call(fc : FunctionCompiler, node : PrimCallNode, dst : Int32, tail : Bool) : Bool
      op = case node.op
           in PrimOp::Add             then Op::Add
           in PrimOp::Sub             then Op::Sub
           in PrimOp::Mul             then Op::Mul
           in PrimOp::NumLt           then Op::NumLt
           in PrimOp::NumLe           then Op::NumLe
           in PrimOp::NumGt           then Op::NumGt
           in PrimOp::NumGe           then Op::NumGe
           in PrimOp::NumEq           then Op::NumEq
           in PrimOp::VectorRef       then Op::VecRef
           in PrimOp::VectorSet       then Op::VecSet
           in PrimOp::VectorLength    then Op::VecLen
           in PrimOp::StringRef       then Op::StrRef
           in PrimOp::StringSet       then Op::StrSet
           in PrimOp::BytevectorU8Ref then Op::BvRef
           in PrimOp::BytevectorU8Set then Op::BvSet
           in PrimOp::Cons            then Op::Cons
           in PrimOp::Not             then Op::Not
           in PrimOp::IsNull          then Op::IsNull
           in PrimOp::IsPair          then Op::IsPair
           in PrimOp::IsEq            then Op::IsEq
           in PrimOp::Cxr             then Op::Cxr
           in PrimOp::Abs             then Op::Abs
           in PrimOp::IsZero          then Op::CmpZero
           in PrimOp::IsPositive      then Op::CmpZero
           in PrimOp::IsNegative      then Op::CmpZero
           end
      # (< n 2)/(- n 1)-shaped calls: a 2-arg arithmetic/comparison op whose
      # 2nd argument is a small-enough integer literal skips staging that
      # literal into its own register + LoadK entirely, baking it directly
      # into the AddImm-family instruction's own operand instead. Only the
      # 2nd position is supported (order matters for the non-commutative
      # ops here, and this is the only shape that occurs in practice) — a
      # non-eligible 2nd argument (not a literal, or a literal too large for
      # Int32) falls through to the general path below unchanged. No
      # all_leaves-style whole-call gate is needed for the 1st argument's
      # own local_register_of? reuse: with the 2nd argument now a pure
      # compile-time constant (no runtime read at all), there is no later
      # sibling whose side effect could invalidate an elided-Move read of
      # the 1st argument — the aliasing hazard the general path's all_leaves
      # gate exists to prevent structurally cannot occur here.
      if node.args.size == 2 && (imm_op = imm_op_for(op)) && (imm = imm_operand?(node.args[1]))
        mark = fc.next_reg
        first_reg = local_register_of?(fc, node.args[0]) || begin
          r = fc.alloc_reg
          compile_expr(fc, node.args[0], r, false)
          r
        end
        fc.reclaim_to(mark)
        prim_src = node.src.write_string
        ip = fc.emit(imm_op, dst, first_reg, imm)
        fc.chunk.tag_sample(ip, node.name, prim_src)
        return false
      end
      # (< i n)-shaped calls: a 2-arg arithmetic/comparison op whose 2nd
      # argument is a bare closed-over variable (an upvalue, e.g. `n`
      # captured by a named-let loop from its enclosing function) skips
      # staging it through its own register + GetUpval, baking the upvalue
      # index directly into the AddUp-family instruction's operand instead
      # — mirrors the Imm case just above exactly, sourcing from an
      # upvalue rather than a compile-time literal. Only the 2nd position
      # is supported, same rationale as Imm. Gated on the 1st argument
      # being a leaf: without that, a side-effecting 1st argument could
      # observe the captured variable at a different point (mutated via a
      # nested set!) than strict left-to-right evaluation would have.
      if node.args.size == 2 && (up_op2 = up_op_for_2nd(op)) && (up_idx2 = up_operand?(fc, node.args[1])) && leaf_node?(node.args[0])
        mark = fc.next_reg
        first_reg = local_register_of?(fc, node.args[0]) || begin
          r = fc.alloc_reg
          compile_expr(fc, node.args[0], r, false)
          r
        end
        fc.reclaim_to(mark)
        prim_src = node.src.write_string
        ip = fc.emit(up_op2, dst, first_reg, up_idx2)
        fc.chunk.tag_sample(ip, node.name, prim_src)
        return false
      end
      # (vector-ref v N)/(string-ref s N)/(bytevector-u8-ref b N)-shaped
      # calls: a Ref/Set op whose INDEX argument is a compile-time
      # integer literal skips staging it through its own register +
      # LoadK, baking it directly into the *RefImm/*SetImm instruction's
      # own operand instead — the Ref/Set-family counterpart of the
      # AddImm-family fusion above, since these ops' index operand isn't
      # covered by imm_op_for's arithmetic/comparison table. Also skips
      # the runtime vector_index_arg/int_arg bounds-checked coercion the
      # base ops still pay (see opcode.cr's *RefImm/*SetImm doc — the
      # index is already a verified Int32 at compile time). Applies just
      # as much to ordinary hand-written Scheme doing fixed-position
      # access as to generated code — a query-compiling #lang dialect
      # like (creme sql-compile), whose every field access resolves to a
      # literal vector index, is simply the single heaviest USER of this,
      # not a special case of it.
      if node.args.size == 2 && (imm_ref_op = imm_index_ref_op_for(op)) && (imm = imm_operand?(node.args[1]))
        mark = fc.next_reg
        # Safe to alias the object's own register directly (no snapshot
        # copy needed): with the index argument now a pure literal, there
        # is no later sibling left at all whose side effect could
        # invalidate an elided-Move read — same reasoning as the
        # arithmetic Imm case above, whose 2nd argument is likewise
        # dropped from the evaluation sequence entirely.
        obj_reg = local_register_of?(fc, node.args[0]) || begin
          r = fc.alloc_reg
          compile_expr(fc, node.args[0], r, false)
          r
        end
        fc.reclaim_to(mark)
        prim_src = node.src.write_string
        ip = fc.emit(imm_ref_op, dst, obj_reg, imm)
        fc.chunk.tag_sample(ip, node.name, prim_src)
        return false
      end
      if node.args.size == 3 && (imm_set_op = imm_index_set_op_for(op)) && (imm = imm_operand?(node.args[1]))
        mark = fc.next_reg
        # Unlike the *RefImm case above, there IS a later argument here
        # (the value, node.args[2]) that could still mutate whatever
        # local variable the object lives in — so the object only
        # qualifies for a direct register-reuse read when that value
        # argument is a leaf (same all_leaves-style reasoning as the
        # general path below); otherwise it must be snapshotted into a
        # fresh register BEFORE the value argument's own (potentially
        # side-effecting) code runs.
        reusable_obj_reg = leaf_node?(node.args[2]) ? local_register_of?(fc, node.args[0]) : nil
        obj_reg = reusable_obj_reg || begin
          r = fc.alloc_reg
          compile_expr(fc, node.args[0], r, false)
          r
        end
        value_reg = local_register_of?(fc, node.args[2]) || begin
          r = fc.alloc_reg
          compile_expr(fc, node.args[2], r, false)
          r
        end
        fc.reclaim_to(mark)
        prim_src = node.src.write_string
        ip = fc.emit(imm_set_op, obj_reg, imm, value_reg)
        fc.chunk.tag_sample(ip, node.name, prim_src)
        fc.emit(Op::Move, dst, obj_reg) unless dst == obj_reg
        return false
      end
      # (vector-ref v i)-shaped calls: a vector/string/bytevector op whose
      # 1st argument (the object) is a bare closed-over variable skips
      # staging it through its own register + GetUpval, baking the upvalue
      # index directly into the *Up-family instruction instead. Gated on
      # every OTHER argument being a leaf — same all_leaves-style reasoning
      # as the general path below, applied to this narrower shape (only
      # the object is ever upvalue-sourced here; the remaining index/value
      # arguments still compile normally).
      if (up_op1 = up_op_for_1st(op)) && (up_idx1 = up_operand?(fc, node.args[0])) && node.args[1..].all? { |arg| leaf_node?(arg) }
        mark = fc.next_reg
        rest_regs = node.args[1..].map do |arg|
          if local_reg = local_register_of?(fc, arg)
            local_reg
          else
            r = fc.alloc_reg
            compile_expr(fc, arg, r, false)
            r
          end
        end
        fc.reclaim_to(mark)
        prim_src = node.src.write_string
        ip = case rest_regs.size
             when 0 then fc.emit(up_op1, dst, up_idx1)
             when 1 then fc.emit(up_op1, dst, up_idx1, rest_regs[0])
             else        fc.emit(up_op1, up_idx1, rest_regs[0], rest_regs[1], dst)
             end
        fc.chunk.tag_sample(ip, node.name, prim_src)
        return false
      end
      # `d` carries the const-pool index of the original Builtin (node.prim)
      # so the VM dispatches to that exact implementation — same semantics/
      # errors, without re-implementing arithmetic/bounds-checking here. The
      # hottest shapes (integer arithmetic, cxr) are further fused into direct
      # Crystal calls in the VM dispatch loop; the rest go through exec_prim.
      builtin_idx = fc.chunk.add_const(node.prim)
      mark = fc.next_reg
      # A bare local-variable argument can read its own register directly
      # instead of being staged through a fresh temp via Move (see
      # local_register_of?) — but only when every argument evaluated AFTER it
      # is a side-effect-free leaf. Otherwise a later non-leaf sibling could
      # mutate the local (via set!/a call) between this argument's snapshot
      # point and when the op runs, and strict left-to-right evaluation
      # requires the pre-mutation value. So an operand qualifies iff its whole
      # suffix is leaves — equivalently, iff its index is past the last
      # non-leaf argument (`last_non_leaf`). The last argument therefore always
      # qualifies (nothing runs after it), which covers the very common
      # `(op (compound…) local)` comparison shape, e.g. `(= (car x) col)`;
      # an all-leaves call has `last_non_leaf == -1` so every operand qualifies.
      last_non_leaf = -1
      node.args.each_with_index { |arg, i| last_non_leaf = i unless leaf_node?(arg) }
      arg_regs = node.args.map_with_index do |arg, i|
        if i > last_non_leaf && (local_reg = local_register_of?(fc, arg))
          local_reg
        else
          r = fc.alloc_reg
          compile_expr(fc, arg, r, false)
          r
        end
      end
      fc.reclaim_to(mark)
      prim_src = node.src.write_string
      fused = false
      case arg_regs.size
      when 1
        # Operand c is op-specific: Op::Cxr packs the car/cdr chain (cxr_code),
        # Op::CmpZero selects the test (0 zero? / 1 positive? / 2 negative?),
        # others leave it 0. Thread the call-site pos: the deopting unary prims
        # (Cxr/Abs/CmpZero) read frame.chunk.positions[ip] to give the deopted
        # builtin's frame the right source location. Harmless (no fast-path
        # effect) for the prims that never read it.
        unary_c = case node.op
                  when PrimOp::Cxr        then cxr_code(node.name)
                  when PrimOp::IsPositive then 1
                  when PrimOp::IsNegative then 2
                  else                         0
                  end
        ip = fc.emit(op, dst, arg_regs[0], unary_c, builtin_idx, node.pos)
        if op == Op::Cxr
          # Profiler: show the fused op ("cxr") in the instruction column and
          # the specific accessor ("car"/"cdr"/"caar"/…) in the expression
          # column, so all uses of one accessor aggregate under it.
          fc.chunk.tag_sample(ip, "cxr", node.name)
        else
          fc.chunk.tag_sample(ip, node.name, prim_src)
        end
      when 2
        # A tail-position call to one of the base arithmetic/comparison
        # ops fuses straight into its own Return-flavored op (see
        # return_op_for/opcode.cr's AddReturn doc) — the general
        # Imm/Up-family shapes above don't get this treatment yet.
        return_op = tail ? return_op_for(op) : nil
        ip = fc.emit(return_op || op, dst, arg_regs[0], arg_regs[1], builtin_idx)
        fc.chunk.tag_sample(ip, node.name, prim_src)
        fused = !return_op.nil?
      when 3
        # 3-arg ops (vector-set!/string-set!/bytevector-u8-set!) have no
        # meaningful result register of their own (R7RS: unspecified) — a=
        # the object, b=index, c=value; the call site's dst just gets the
        # object back afterward, matching those forms' typical `(begin
        # (vector-set! ...) v)`-style usage.
        ip = fc.emit(op, arg_regs[0], arg_regs[1], arg_regs[2], builtin_idx)
        fc.chunk.tag_sample(ip, node.name, prim_src)
        fc.emit(Op::Move, dst, arg_regs[0]) unless dst == arg_regs[0]
      end
      fused
    end

    # Encode a cxr accessor name's car/cdr chain into the Op::Cxr `c` operand:
    # each `a`/`d` letter between the leading `c` and trailing `r` becomes one
    # bit (a=1/car, d=0/cdr), with a sentinel top bit marking the chain length.
    # The VM applies bits LSB-first, which is innermost-first (the letter
    # nearest `r`), so `(caddr x)` = car(cdr(cdr x)) decodes to cdr,cdr,car.
    # E.g. car→0b11, cdr→0b10, caddr→0b1100.
    private def cxr_code(name : String) : Int32
      code = 1
      name.each_char_with_index do |letter, i|
        next if i == 0 || i == name.size - 1
        code = (code << 1) | (letter == 'a' ? 1 : 0)
      end
      code
    end

    # If `node` is a bare variable-reference callee, its {resolution kind,
    # d-operand} for a fused Call*/TailCall* op — {:global, const index},
    # {:local, callee register}, or {:upvalue, upvalue index}. nil for a
    # compound callee (a nested call, an inline lambda, etc.), which must go
    # through the general compile_expr-into-callee-register path instead.
    private def bare_callee_source(fc : FunctionCompiler, node : Node) : {Symbol, Int32}?
      name = case node
             when VarRefNode    then node.name
             when LocalRefNode  then node.name
             when GlobalRefNode then node.name
             else                    return nil
             end
      kind, idx = resolve_variable(fc, name)
      case kind
      when :local, :upvalue then {kind, idx}
      else                       {:global, fc.chunk.add_const(SchemeSym.of(name))}
      end
    end

    # ameba:disable Metrics/CyclomaticComplexity
    private def compile_app(fc : FunctionCompiler, node : AppNode, dst : Int32, tail : Bool) : Nil
      call_src = node.src.write_string
      # Bare-name callee: fuse the callee load (GetGlobal/Move/GetUpval) into
      # the call itself. The anchor register is still allocated (so args stay
      # contiguous at anchor+1..) but the callee is never written into it —
      # the fused op's `d` operand says where to fetch it (see exec_call_*).
      if source = bare_callee_source(fc, node.callee)
        kind, operand = source
        op = case {kind, tail}
             when {:global, false}  then Op::CallGlobal
             when {:global, true}   then Op::TailCallGlobal
             when {:local, false}   then Op::CallLocal
             when {:local, true}    then Op::TailCallLocal
             when {:upvalue, false} then Op::CallUpval
             else                        Op::TailCallUpval
             end
        # A TAIL call always reuses the CURRENT frame's own base as its new
        # frame's base (dispatch_call/exec_call*'s `new_base = tail ?
        # caller_base : ...`, mirrored in icecreme/vm.c) — so if every argument is
        # a leaf_node? (no nested calls/closures — see leaf_node?'s own use
        # for prim-call operand fusion above), compile them directly into
        # registers 0..n-1 instead of a floating anchor+1.. run: anchor=-1
        # makes `arg_base == caller_base` (arg_base = caller_base + a + 1),
        # so the runtime's own arg-binding copy becomes a same-address
        # no-op, AND a bare variable-passthrough argument needs no Move at
        # all — compile_name_read already elides the Move whenever dst
        # equals the variable's own register, which registers 0..n-1
        # frequently already are for a loop's own accumulator arguments.
        # See compile_tail_call_args_in_place's own doc comment for why this
        # is safe regardless of what the callee turns out to be at runtime.
        # Also requires none of registers 0...n-1 to ever have been captured
        # as a from_parent_local upvalue anywhere in this function — see
        # FunctionCompiler#captured_registers's own doc comment for why an
        # open upvalue into one of these registers can't tolerate an early
        # direct-write, even a deferred/settled one.
        if tail && node.args.all? { |arg| leaf_node?(arg) } &&
           (0...node.args.size).none? { |target_reg| fc.captured_registers.includes?(target_reg) }
          anchor = -1
          safe_operand = compile_tail_call_args_in_place(fc, node.args, kind, kind == :global ? nil : operand)
          ip = fc.emit(op, anchor, node.args.size, 0, safe_operand || operand, pos: node.pos)
          fc.chunk.tag_sample(ip, "call", call_src)
          return
        end
        mark = fc.next_reg
        # anchor, then args in the contiguous run right above it
        # (anchor+1..), reserved for the WHOLE run in one alloc_regs bump —
        # BEFORE compiling ANY argument's own expression — exactly like the
        # generic-callee path below and self-hosted compiler.sld's own
        # compile-ordinary-app! — a non-leaf argument (e.g. a let/letrec
        # with its own captured-register floor) can otherwise leave
        # next_reg higher than expected once its own scope pops, shifting
        # where a LATER argument's register lands and breaking this
        # contiguity (verified empirically: this is what made generalizing
        # pop_scope's captured-register floor unsafe here, even though the
        # self-hosted compiler's own general version of that same floor is
        # safe — it already reserves this way).
        anchor = fc.alloc_regs(1 + node.args.size)
        node.args.each_with_index { |arg, i| compile_expr(fc, arg, anchor + 1 + i, false) }
        ip = if tail
               fc.emit(op, anchor, node.args.size, 0, operand, pos: node.pos)
             else
               fc.emit(op, anchor, node.args.size, dst, operand, pos: node.pos)
             end
        fc.chunk.tag_sample(ip, "call", call_src)
        fc.reclaim_to(mark)
        return
      end
      mark = fc.next_reg
      # callee_reg, then args contiguous immediately after it, for Call/
      # TailCall — reserved together in one alloc_regs bump BEFORE compiling
      # EITHER the callee or any argument's own expression — same reasoning
      # as the bare-callee path above: a non-leaf callee or argument (its
      # own nested call/let/lambda) could otherwise shift where a later
      # register lands once its own scope pops.
      callee_reg = fc.alloc_regs(1 + node.args.size)
      compile_expr(fc, node.callee, callee_reg, false)
      node.args.each_with_index { |arg, i| compile_expr(fc, arg, callee_reg + 1 + i, false) }
      if tail
        ip = fc.emit(Op::TailCall, callee_reg, node.args.size, pos: node.pos)
        fc.chunk.tag_sample(ip, "call", call_src)
      else
        ip = fc.emit(Op::Call, callee_reg, node.args.size, dst, pos: node.pos)
        fc.chunk.tag_sample(ip, "call", call_src)
      end
      fc.reclaim_to(mark)
    end
  end
end
