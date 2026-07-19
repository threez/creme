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

module Scheme
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

    def push_scope : Nil
      @scope = CompilerScope.new(@scope, @next_reg)
    end

    def pop_scope : Nil
      cur = @scope || raise "internal: pop_scope with no active scope"
      @next_reg = cur.saved_next_reg
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
    # local's own register to some later, unrelated temp. Safe to call
    # unconditionally (no scope at all — true top level — just uses `mark`
    # directly, since nothing declare_local'd there needs protecting).
    def reclaim_to(mark : Int32) : Nil
      floor = @scope.try(&.persistent_high_water) || mark
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
    # value is returned (matching Scheme.run_source's per-form semantics).
    def self.compile_program(nodes : Array(Node)) : Chunk
      fc = FunctionCompiler.new(nil, "program", is_toplevel: true)
      new.compile_body(fc, nodes, tail: true)
      fc.chunk
    end

    # Analyzes, compiles, and runs each top-level form in turn — mirroring
    # Scheme.run_source's own per-form loop (runner.cr) — rather than
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
            Scheme.record_type_names(node.form).try do |names|
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
        return add_upvalue(fc, true, reg, name)
      end
      if idx = resolve_upvalue(parent, name)
        return add_upvalue(fc, false, idx, name)
      end
      nil
    end

    private def add_upvalue(fc : FunctionCompiler, from_parent_local : Bool, index : Int32, name : String) : Int32
      fc.chunk.upvalues.each_with_index do |existing, i|
        return i if existing.from_parent_local == from_parent_local && existing.index == index
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

    private def compile_named_let(fc : FunctionCompiler, node : NamedLetNode, dst : Int32, tail : Bool) : Nil
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
      fc.push_scope
      loop_name = "%do-loop-#{@loop_counter += 1}"
      loop_reg = fc.declare_local(loop_name)
      dummy_src = Cons.new(NIL, NIL)
      step_args = node.names.map_with_index do |name, i|
        node.steps[i] || VarRefNode.new(name)
      end.map(&.as(Node))
      step_call = AppNode.new(VarRefNode.new(loop_name), step_args, dummy_src)
      loop_body = IfNode.new(node.test, BeginNode.new(node.results), BeginNode.new(node.commands + [step_call.as(Node)]))
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
    # Scheme.scheme_eqv?'s own type dispatch in helpers.cr): SchemeInt,
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
      params.each { |p| child.declare_local(p) }
      rest_name = rest
      child.declare_local(rest_name) if rest_name
      child.chunk.param_count = params.size
      child.chunk.has_rest = !rest_name.nil?
      compile_body(child, body, tail: true)
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
          names = Scheme.record_type_names(node.form)
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

    private def compile_app(fc : FunctionCompiler, node : AppNode, dst : Int32, tail : Bool) : Nil
      call_src = node.src.write_string
      # Bare-name callee: fuse the callee load (GetGlobal/Move/GetUpval) into
      # the call itself. The anchor register is still allocated (so args stay
      # contiguous at anchor+1..) but the callee is never written into it —
      # the fused op's `d` operand says where to fetch it (see exec_call_*).
      if source = bare_callee_source(fc, node.callee)
        kind, operand = source
        mark = fc.next_reg
        anchor = fc.alloc_reg
        # Args go in the contiguous run right above the anchor (anchor+1..),
        # exactly as the general path below — nothing shrinks next_reg between
        # these allocations, so they stay contiguous.
        node.args.each { |arg| compile_expr(fc, arg, fc.alloc_reg, false) }
        op = case {kind, tail}
             when {:global, false}  then Op::CallGlobal
             when {:global, true}   then Op::TailCallGlobal
             when {:local, false}   then Op::CallLocal
             when {:local, true}    then Op::TailCallLocal
             when {:upvalue, false} then Op::CallUpval
             else                        Op::TailCallUpval
             end
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
      callee_reg = fc.alloc_reg
      compile_expr(fc, node.callee, callee_reg, false)
      arg_regs = node.args.map { |arg| r = fc.alloc_reg; compile_expr(fc, arg, r, false); r }
      # Args must be contiguous immediately after callee_reg for Call/TailCall
      # — true here since nothing shrinks next_reg between these allocations.
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
