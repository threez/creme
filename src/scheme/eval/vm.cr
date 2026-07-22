# ===========================================================================
# VM: the register-bytecode dispatch loop
# ===========================================================================
#
# Executes a Chunk (see compile/chunk.cr) produced by BytecodeCompiler.
# Deliberately iterative (an explicit call-frame stack), not recursive
# Crystal calls — this is what lets call/cc, dynamic-wind, and guard unwind
# to an arbitrary saved depth of this same stack rather than relying on
# Crystal's own call stack/exceptions.
#
# Registers live in ONE shared, growable `@stack` array — each CallFrame is
# just a `base` offset into it (Lua-style), not its own freshly allocated
# Array. A non-tail Call pushes a new frame's window immediately above its
# caller's (`base + caller.chunk.num_registers`); a TailCall reuses the
# CURRENT frame's exact base, so a self-tail-recursive loop never grows the
# stack at all — genuinely O(1) space.
#
# CallFrame objects themselves are ALSO pooled by depth in `@frames`, rather
# than allocated fresh per call: `@depth` tracks how many are currently live,
# and pushing a call at a depth already covered by a previous (since-
# returned) call REUSES that same CallFrame object, just overwriting its
# fields — recursion depth bounds how many CallFrame objects a whole run
# ever needs (e.g. ~27 for fib(27), not one per each of its ~630,000 calls).
# Allocating both a fresh register Array AND a fresh CallFrame per call would
# be measurably slower on fib/sum-to workloads; this pooled-stack design
# avoids both allocations on the hot path.
#
# Because register slots (and now CallFrame objects) are genuinely reused
# across calls, any Upvalue capturing "an open register in a still-live
# frame" must be CLOSED (its value copied out, detached from `@stack`) the
# instant that frame exits — at a Return or at a TailCall replacing it — or
# a subsequent call reusing that stack region would silently corrupt the
# captured value. See `close_upvalues`/CallFrame#opened_upvalues.

module Scheme
  class CallFrame
    property chunk : Chunk
    property base : Int32
    property closure : BytecodeClosure?
    property ip : Int32 = 0
    # Register index, in the frame that becomes the new top-of-stack after
    # this frame is popped, to receive this frame's Return value. nil only
    # for the outermost frame (its "return" is the VM's own result).
    property return_reg : Int32?
    # Upvalues opened (by a Closure instruction) against THIS frame's own
    # registers — closed (see VM#close_upvalues) the instant this frame
    # exits, before its stack region (and this pooled object itself) can be
    # reused by a later call. Lazily allocated: most frames (anything
    # closure_free) never populate this.
    property opened_upvalues : Array(Upvalue)?
    # Where THIS frame's GetGlobal/DefGlobal/SetGlobal/HelperForm operate —
    # inherited from whatever env was active when the closure now running
    # in this frame was CREATED (see VM#make_closure), not from whichever
    # VM instance/caller happens to be running it. A closure that escapes
    # its defining scope (e.g. a library export called from unrelated user
    # code) must still resolve its own free variables against the env it
    # was compiled under — standard lexical-scope capture — not wherever
    # it's being called FROM.
    property root_env : Env
    # Whether an Interpreter::Frame currently exists on @call_stack for THIS
    # activation — used by exec_call's tail-call path to tell "collapse
    # into the existing interpreter frame" (already true) apart from "push
    # a new one" (not yet true). Deliberately NOT reset by `reset` below —
    # a tail-call reset REUSES the same @call_stack slot/identity across
    # iterations, only a genuinely NEW activation (via VM#push_frame's
    # pool-reuse branch) needs it cleared, which its callers do explicitly.
    property has_interp_frame : Bool = false
    # Whether THIS VM's deliver_return is the one that should pop that
    # frame — false for the one case where has_interp_frame is true but
    # something ELSE already owns the push/pop (Interpreter#apply's
    # BytecodeClosure/BytecodeCaseClosure arms push a Frame before calling
    # VM#call and pop it in their own `ensure`, exactly like the Lambda arm
    # — VM#call marks its outermost frame accordingly so deliver_return
    # doesn't ALSO pop it, double-popping @call_stack).
    property owns_interp_frame : Bool = false

    def initialize(@chunk : Chunk, @base : Int32, @closure : BytecodeClosure?, @return_reg : Int32?, @root_env : Env)
    end

    # Overwrites this (pooled, reused) frame's fields for a new activation.
    # Deliberately leaves has_interp_frame/owns_interp_frame untouched — see
    # their own doc comments; every call site (VM#push_frame, exec_call's
    # tail-call path) manages those two explicitly for its own scenario.
    def reset(chunk : Chunk, base : Int32, closure : BytecodeClosure?, return_reg : Int32?, root_env : Env) : Nil
      @chunk = chunk
      @base = base
      @closure = closure
      @return_reg = return_reg
      @root_env = root_env
      @ip = 0
      @opened_upvalues = nil
    end
  end

  # A pending cleanup action to run when execution unwinds past the point it
  # was pushed — the VM's explicit stand-in for the `ensure`/exception
  # unwinding a recursive Crystal evaluator would get for free. `parameterize`
  # pushes one to restore its saved parameter values; `dynamic-wind` pushes one
  # to run its `after` thunk. Popped/run in LIFO order by ParamPop on normal
  # exit; on an abnormal unwind (see handle_guarded_error) every UnwindAction
  # between the raise site and the handler's depth is run, not just whatever a
  # normal ParamPop would reach.
  abstract class UnwindAction
    abstract def run : Nil
  end

  class ParamRestoreAction < UnwindAction
    def initialize(@params : Array(SchemeParameter), @saved : Array(SchemeValue))
    end

    def run : Nil
      @params.each_with_index { |param, i| param.value = @saved[i] }
    end
  end

  # An installed `guard`'s dynamic extent — see PushHandler/handle_guarded_
  # error. `frame`/`depth` identify the activation guard was compiled into
  # (never mutated out from under an active handler, since guard's own
  # protected body is always compiled non-tail — see compile_guard);
  # `unwind_mark` is the @unwind_stack depth to unwind back to (running
  # every pending action above it) if an error is caught here; `resume_ip`
  # is where clause-checking code starts; `condition_reg` is where the
  # synthesized condition value is written before jumping there.
  struct GuardHandler
    getter depth : Int32
    getter frame : CallFrame
    getter unwind_mark : Int32
    getter condition_reg : Int32
    getter resume_ip : Int32

    def initialize(@depth : Int32, @frame : CallFrame, @unwind_mark : Int32, @condition_reg : Int32, @resume_ip : Int32)
    end
  end

  class VM
    # `root_env` seeds the OUTERMOST frame's root_env (see CallFrame#root_env)
    # for a fresh `run` call — defaults to interp.global (an ordinary
    # program), but a library body compiles/runs against its OWN env, and
    # (scheme eval)'s `eval` procedure / `load` / the prelude each target
    # whatever env their caller specifies. Every frame below the outermost
    # gets its root_env from whichever closure it's running (inherited from
    # that closure's OWN creation-time frame), not from this VM instance —
    # this ivar only matters for `run`'s initial push; `call`'s (the bridge
    # from Interpreter#apply) uses the closure's own root_env directly and
    # ignores it entirely. Env#get/set! already walk their own parent chain
    # internally, so targeting a non-root env (e.g. a child env built for
    # `eval`'s optional bindings) still resolves free variables correctly —
    # only `define`'s "always local to THIS env" semantics actually depend
    # on which exact env is passed.
    def initialize(@interp : Interpreter, root_env : Env? = nil)
      @root_env = root_env || @interp.global
      @stack = Array(SchemeValue).new(256, NIL)
      @frames = [] of CallFrame
      @depth = 0
      @unwind_stack = [] of UnwindAction
      @handlers = [] of GuardHandler
      @pending_reraise = nil.as(SchemeError?)
    end

    # Interpreter.push_current/pop_current lets SchemeError#initialize find
    # the active interpreter (to snapshot call_stack_snapshot/current_pos)
    # without needing an explicit reference threaded to every raise site.
    def run(chunk : Chunk) : SchemeValue
      Interpreter.push_current(@interp)
      begin
        ensure_stack_size(chunk.num_registers)
        push_frame(chunk, 0, nil, nil, @root_env)
        sampling_execute
      ensure
        Interpreter.pop_current
      end
    end

    # Invoked from Interpreter#apply whenever a builtin (map, for-each, sort,
    # apply, call-with-values, ...) calls back into a BytecodeClosure value —
    # runs the closure to completion in a fresh frame stack and returns its
    # result, bridging Interpreter#apply's convention to the VM.
    # apply already pushed an Interpreter::Frame for this exact activation
    # (it does so for every closure it runs) — mark it so a later self-tail-call from
    # THIS closure correctly overwrites that frame instead of pushing a
    # second one on top of it.
    def call(closure : BytecodeClosure, args : Array(SchemeValue)) : SchemeValue
      Interpreter.push_current(@interp)
      begin
        ensure_stack_size(closure.chunk.num_registers)
        bind_args_from_array(closure.chunk, args, 0, @stack)
        push_frame(closure.chunk, 0, closure, nil, closure.root_env)
        top_frame.has_interp_frame = true
        sampling_execute
      ensure
        Interpreter.pop_current
      end
    end

    # Returns this VM to a clean, ready-to-reuse state so a single instance
    # can be pooled across many Interpreter#apply calls instead of allocated
    # fresh each time (see ObjectPool / Interpreter#vm_pool). After a normal
    # `call` the VM is already clean (@depth back to 0, handler/unwind stacks
    # balanced to empty); this also covers the exception-unwound case, where
    # `call` left @depth > 0 or a partial handler/unwind stack behind. @stack
    # and the @frames pool keep their capacity (their contents are always
    # overwritten before being read on the next call), so reuse is O(1) — the
    # whole point. Continuations capture only an Int64 tag, never VM state
    # (see Interpreter#apply / SchemeContinuation), so a reused VM can't
    # corrupt an escape continuation captured during an earlier call.
    def reset_for_reuse : Nil
      @depth = 0
      @handlers.clear
      @unwind_stack.clear
      @pending_reraise = nil
    end

    private def ensure_stack_size(min_size : Int32) : Nil
      while @stack.size < min_size
        @stack << NIL
      end
    end

    # Pushes a new activation at `@depth`, reusing the CallFrame object
    # already pooled there (from an earlier, since-returned call at the
    # same depth) if one exists, else growing the pool by one.
    private def push_frame(chunk : Chunk, base : Int32, closure : BytecodeClosure?, return_reg : Int32?, root_env : Env) : Nil
      if @depth < @frames.size
        frame = @frames[@depth]
        frame.reset(chunk, base, closure, return_reg, root_env)
        # A genuinely NEW activation at this depth — any leftover interp-
        # frame bookkeeping from whatever PREVIOUS activation last used
        # this pooled slot is stale; callers (VM#run/call, exec_call) set
        # these to the correct values for their own scenario right after.
        frame.has_interp_frame = false
        frame.owns_interp_frame = false
      else
        @frames << CallFrame.new(chunk, base, closure, return_reg, root_env)
      end
      @depth += 1
    end

    private def top_frame : CallFrame
      # @depth is >= 1 for the whole lifetime of an executing VM (the
      # outermost frame is pushed before execute runs and popped only as the
      # VM returns), so @depth - 1 is always a valid @frames index.
      @frames.unsafe_fetch(@depth - 1)
    end

    # Re-derives the (frame, base, instructions) triplet execute's dispatch
    # loop caches across iterations — called only right after an op that can
    # change which frame is on top: a non-tail call (pushed one), a tail call
    # (rewrote the current frame's own base/chunk in place — same CallFrame
    # object, but `base`/`instructions` still need re-reading), a
    # Return-family op (popped one), or guard's handle_guarded_error
    # (unwinds @depth to an arbitrary saved depth). Every other instruction
    # never touches @depth, so it never calls this — see execute's own doc
    # comment.
    private def refresh_frame : {CallFrame, Int32, Array(Instruction)}
      f = top_frame
      {f, f.base, f.chunk.instructions}
    end

    # Wrapped in a begin/rescue INSIDE the loop (not around the whole
    # method) so a caught SchemeError resumes the SAME loop rather than
    # unwinding out of `execute` entirely — guard's whole mechanism is
    # "catch here, jump to some other ip, keep running", not "return early".
    #
    # Generated in all 4 combinations by the macro loop below — plain
    # `execute` (used whenever neither (creme prof)'s Scheme-level sampler
    # nor a max_steps budget is active), `execute_sampled`, `execute_limited`,
    # and `execute_sampled_limited` (each identical except for one extra
    # check per dispatched instruction per active concern) — rather than
    # written once with runtime `if @interp.sample_interval`/`if
    # @interp.max_steps` checks inside the loop. A single guarded branch like
    # that was tried first (for sampling) and measurably regressed
    # bench.scm (~15%) even though the condition is false on every non-
    # profiled run, apparently by bloating/deoptimizing this loop's codegen;
    # textually-duplicated methods (the plain `execute` variant genuinely
    # contains neither sampling nor step-limit code at all) keep the
    # ordinary path byte-for-byte what it was before either concern existed,
    # at the cost of authoring the dispatch body once in source but
    # compiling it up to 4 times. #run/#call pick whichever to call via
    # #sampling_execute, checked ONCE per top-level entry rather than once
    # per instruction — safe since (creme prof)'s profile-scheme always
    # calls start_scheme_sampling strictly before, and stop_scheme_sampling
    # strictly after, the apply/VM#run|call that reaches this method, so no
    # single execute*/call's lifetime ever spans a start/stop boundary
    # (including a nested VM instance created for a callback invoked
    # mid-sample, e.g. map/for-each calling back into apply — its own
    # #sampling_execute re-checks the still-active interval/limit
    # independently); max_steps is an ordinary property so the same
    # once-per-entry check is equally safe for it.
    {% for sampled in [false, true] %}
    {% for limited in [false, true] %}
    private def execute{{ "_sampled".id if sampled }}{{ "_limited".id if limited }} : SchemeValue
      # `frame`/`base`/`instructions` used to be re-derived from `top_frame`
      # at the top of EVERY instruction, even though only a call (push),
      # tail call (rewrites the current frame's own base/chunk in place), a
      # Return-family op (pop), or guard unwinding (handle_guarded_error,
      # below) can actually change which frame is on top or where it starts
      # — every other op (LoadK/Move/Add/Cxr/jumps/...) never touches
      # `@depth` at all. Caching them across iterations and refreshing only
      # right after one of those specific ops (via `refresh_frame`, see its
      # own doc comment) skips that unconditional @frames.unsafe_fetch +
      # field-read pair on the hot majority of instructions instead of
      # paying it on every single one.
      frame, base, instructions = refresh_frame
      loop do
        begin
          {% if sampled %}
            sampled_ip = frame.ip
          {% end %}
          # Bounds-check-free fetch, with NO per-instruction end-of-chunk
          # guard: frame.ip is provably always in range because every chunk
          # ends in a Return sentinel and no jump can target past it (see
          # BytecodeCompiler#append_return_sentinel), so execution always
          # leaves a chunk via a Return before ip could reach instructions.size
          # — sequentially or by jump. Dropping the guard's per-instruction
          # branch is a measurable win on tight loops (e.g. sum-to ~12%,
          # fib ~6%). A malformed chunk lacking the sentinel would read out of
          # bounds here rather than raising; that invariant is the compiler's
          # to keep.
          instr = instructions.unsafe_fetch(frame.ip)
          frame.ip += 1
          {% if sampled %}
            if interval = @interp.sample_interval
              @interp.tick_sample(interval, frame.chunk, sampled_ip)
            end
          {% end %}
          {% if limited %}
            if limit = @interp.max_steps
              @interp.tick_step_limit(limit)
            end
          {% end %}
          case instr.op
          when Op::LoadK
            # Bounds-check-free: `instr.b` is always a const-pool index
            # BytecodeCompiler obtained from THIS chunk's own `add_const`
            # call, so it's provably < chunk.consts.size (same reasoning as
            # `top_frame`'s @frames.unsafe_fetch above) — every other
            # `chunk.consts`/`chunk.protos`/`chunk.qq_templates`/
            # `chunk.case_dispatch_tables` access in this file (all indexed by
            # an operand BytecodeCompiler obtained from that same chunk's own
            # add_const/add_proto/add_qq_template/add_case_dispatch_table
            # call) shares this same argument without repeating the comment.
            @stack.unsafe_put(base + instr.a, frame.chunk.consts.unsafe_fetch(instr.b))
          when Op::LoadNil
            @stack.unsafe_put(base + instr.a, NIL)
          when Op::LoadTrue
            @stack.unsafe_put(base + instr.a, TRUE)
          when Op::LoadFalse
            @stack.unsafe_put(base + instr.a, FALSE)
          when Op::Move
            @stack.unsafe_put(base + instr.a, @stack.unsafe_fetch(base + instr.b))
          when Op::GetUpval
            @stack.unsafe_put(base + instr.a, upvalue(frame, instr.b).get)
          when Op::SetUpval
            upvalue(frame, instr.a).set(@stack.unsafe_fetch(base + instr.b))
          when Op::GetGlobal
            @stack.unsafe_put(base + instr.a, get_global_cached(frame, frame.ip - 1, instr.b))
          when Op::DefGlobal
            name = const_name(frame, instr.a)
            frame.root_env.define(name, @stack.unsafe_fetch(base + instr.b))
          when Op::SetGlobal
            name = const_name(frame, instr.a)
            frame.root_env.set!(name, @stack.unsafe_fetch(base + instr.b))
          when Op::Add
            # The hottest prim shapes (base + Imm integer arithmetic) are
            # inlined directly here rather than routed through exec_prim's own
            # second `case` + method call — the double dispatch that Op::Add..
            # was paying. Semantics/fallbacks are byte-for-byte exec_prim's
            # (same int fast path, same @interp.num_* general fallback). The
            # rarer/heavier prim shapes (Up/vector/string/bytevector/cons/
            # predicates) stay in exec_prim below.
            x = @stack.unsafe_fetch(base + instr.b); y = @stack.unsafe_fetch(base + instr.c)
            @stack.unsafe_put(base + instr.a, if x.is_a?(SchemeInt) && y.is_a?(SchemeInt)
              begin
                SchemeInt.new(x.value + y.value)
              rescue OverflowError
                @interp.num_add(x, y, "+")
              end
            else
              @interp.num_add(x, y, "+")
            end)
          when Op::Sub
            x = @stack.unsafe_fetch(base + instr.b); y = @stack.unsafe_fetch(base + instr.c)
            @stack.unsafe_put(base + instr.a, if x.is_a?(SchemeInt) && y.is_a?(SchemeInt)
              begin
                SchemeInt.new(x.value - y.value)
              rescue OverflowError
                @interp.num_sub(x, y, "-")
              end
            else
              @interp.num_sub(x, y, "-")
            end)
          when Op::Mul
            x = @stack.unsafe_fetch(base + instr.b); y = @stack.unsafe_fetch(base + instr.c)
            @stack.unsafe_put(base + instr.a, if x.is_a?(SchemeInt) && y.is_a?(SchemeInt)
              begin
                SchemeInt.new(x.value * y.value)
              rescue OverflowError
                @interp.num_mul(x, y, "*")
              end
            else
              @interp.num_mul(x, y, "*")
            end)
          when Op::AddImm
            x = @stack.unsafe_fetch(base + instr.b)
            @stack.unsafe_put(base + instr.a, if x.is_a?(SchemeInt)
              begin
                SchemeInt.new(x.value + instr.c.to_i64)
              rescue OverflowError
                @interp.num_add(x, SchemeInt.new(instr.c.to_i64), "+")
              end
            else
              @interp.num_add(x.as(SchemeValue), SchemeInt.new(instr.c.to_i64), "+")
            end)
          when Op::SubImm
            x = @stack.unsafe_fetch(base + instr.b)
            @stack.unsafe_put(base + instr.a, if x.is_a?(SchemeInt)
              begin
                SchemeInt.new(x.value - instr.c.to_i64)
              rescue OverflowError
                @interp.num_sub(x, SchemeInt.new(instr.c.to_i64), "-")
              end
            else
              @interp.num_sub(x.as(SchemeValue), SchemeInt.new(instr.c.to_i64), "-")
            end)
          when Op::MulImm
            x = @stack.unsafe_fetch(base + instr.b)
            @stack.unsafe_put(base + instr.a, if x.is_a?(SchemeInt)
              begin
                SchemeInt.new(x.value * instr.c.to_i64)
              rescue OverflowError
                @interp.num_mul(x, SchemeInt.new(instr.c.to_i64), "*")
              end
            else
              @interp.num_mul(x.as(SchemeValue), SchemeInt.new(instr.c.to_i64), "*")
            end)
          when Op::NumLt, Op::NumLe, Op::NumGt, Op::NumGe, Op::NumEq,
               Op::NumLtImm, Op::NumLeImm, Op::NumGtImm, Op::NumGeImm, Op::NumEqImm,
               Op::AddUp, Op::SubUp, Op::MulUp, Op::NumLtUp, Op::NumLeUp, Op::NumGtUp, Op::NumGeUp, Op::NumEqUp,
               Op::VecRef, Op::VecLen, Op::StrRef, Op::BvRef, Op::VecSet, Op::StrSet, Op::BvSet,
               Op::VecRefUp, Op::VecSetUp, Op::VecLenUp, Op::StrRefUp, Op::StrSetUp, Op::BvRefUp, Op::BvSetUp,
               Op::VecRefImm, Op::VecSetImm, Op::StrRefImm, Op::StrSetImm, Op::BvRefImm, Op::BvSetImm,
               Op::Cons, Op::Not, Op::IsNull, Op::IsPair,
               Op::IsEq, Op::IsEqImm, Op::IsEqUp
            exec_prim(frame, base, instr)
          when Op::CaseMatch
            key = @stack.unsafe_fetch(base + instr.b)
            datums = frame.chunk.consts.unsafe_fetch(instr.c).as(SchemeVector).value
            @stack.unsafe_put(base + instr.a, SchemeBool.of(datums.any? { |datum| Scheme.scheme_eqv?(key, datum) }))
          when Op::CaseDispatch
            key = @stack.unsafe_fetch(base + instr.a)
            table = frame.chunk.case_dispatch_tables.unsafe_fetch(instr.b)
            dispatch_key = case key
                           when SchemeInt  then CaseDispatchKey.for_int(key.value)
                           when SchemeChar then CaseDispatchKey.for_char(key.value)
                           when SchemeSym  then CaseDispatchKey.for_sym(key.name)
                           when SchemeBool then CaseDispatchKey.for_bool(key.value?)
                           when SchemeNil  then CaseDispatchKey::NIL
                           else                 nil
                           end
            frame.ip = (dispatch_key && table.targets[dispatch_key]?) || table.default
          when Op::Throw
            raise SchemeRuntimeError.new(frame.chunk.consts.unsafe_fetch(instr.a).as(SchemeStr).value)
          when Op::Jmp
            frame.ip += instr.b
          when Op::TestFalse
            frame.ip += instr.b if falsy?(@stack.unsafe_fetch(base + instr.a))
          when Op::TestLt
            x = @stack.unsafe_fetch(base + instr.a); y = @stack.unsafe_fetch(base + instr.c)
            truthy = x.is_a?(SchemeInt) && y.is_a?(SchemeInt) ? x.value < y.value : begin
              cmp = @interp.num_compare2(x, y, "<")
              !cmp.nil? && cmp < 0
            end
            frame.ip += instr.b unless truthy
          when Op::TestLe
            x = @stack.unsafe_fetch(base + instr.a); y = @stack.unsafe_fetch(base + instr.c)
            truthy = x.is_a?(SchemeInt) && y.is_a?(SchemeInt) ? x.value <= y.value : begin
              cmp = @interp.num_compare2(x, y, "<=")
              !cmp.nil? && cmp <= 0
            end
            frame.ip += instr.b unless truthy
          when Op::TestGt
            x = @stack.unsafe_fetch(base + instr.a); y = @stack.unsafe_fetch(base + instr.c)
            truthy = x.is_a?(SchemeInt) && y.is_a?(SchemeInt) ? x.value > y.value : begin
              cmp = @interp.num_compare2(x, y, ">")
              !cmp.nil? && cmp > 0
            end
            frame.ip += instr.b unless truthy
          when Op::TestGe
            x = @stack.unsafe_fetch(base + instr.a); y = @stack.unsafe_fetch(base + instr.c)
            truthy = x.is_a?(SchemeInt) && y.is_a?(SchemeInt) ? x.value >= y.value : begin
              cmp = @interp.num_compare2(x, y, ">=")
              !cmp.nil? && cmp >= 0
            end
            frame.ip += instr.b unless truthy
          when Op::TestEq
            x = @stack.unsafe_fetch(base + instr.a); y = @stack.unsafe_fetch(base + instr.c)
            truthy = x.is_a?(SchemeInt) && y.is_a?(SchemeInt) ? x.value == y.value : begin
              cmp = @interp.num_compare2(x, y, "=")
              !cmp.nil? && cmp == 0
            end
            frame.ip += instr.b unless truthy
          when Op::TestLtImm
            x = @stack.unsafe_fetch(base + instr.a)
            truthy = x.is_a?(SchemeInt) ? x.value < instr.c.to_i64 : begin
              cmp = @interp.num_compare2(x.as(SchemeValue), SchemeInt.new(instr.c.to_i64), "<")
              !cmp.nil? && cmp < 0
            end
            frame.ip += instr.b unless truthy
          when Op::TestLeImm
            x = @stack.unsafe_fetch(base + instr.a)
            truthy = x.is_a?(SchemeInt) ? x.value <= instr.c.to_i64 : begin
              cmp = @interp.num_compare2(x.as(SchemeValue), SchemeInt.new(instr.c.to_i64), "<=")
              !cmp.nil? && cmp <= 0
            end
            frame.ip += instr.b unless truthy
          when Op::TestGtImm
            x = @stack.unsafe_fetch(base + instr.a)
            truthy = x.is_a?(SchemeInt) ? x.value > instr.c.to_i64 : begin
              cmp = @interp.num_compare2(x.as(SchemeValue), SchemeInt.new(instr.c.to_i64), ">")
              !cmp.nil? && cmp > 0
            end
            frame.ip += instr.b unless truthy
          when Op::TestGeImm
            x = @stack.unsafe_fetch(base + instr.a)
            truthy = x.is_a?(SchemeInt) ? x.value >= instr.c.to_i64 : begin
              cmp = @interp.num_compare2(x.as(SchemeValue), SchemeInt.new(instr.c.to_i64), ">=")
              !cmp.nil? && cmp >= 0
            end
            frame.ip += instr.b unless truthy
          when Op::TestEqImm
            x = @stack.unsafe_fetch(base + instr.a)
            truthy = x.is_a?(SchemeInt) ? x.value == instr.c.to_i64 : begin
              cmp = @interp.num_compare2(x.as(SchemeValue), SchemeInt.new(instr.c.to_i64), "=")
              !cmp.nil? && cmp == 0
            end
            frame.ip += instr.b unless truthy
          when Op::TestLtUp
            x = @stack.unsafe_fetch(base + instr.a); y = upvalue(frame, instr.c).get
            truthy = x.is_a?(SchemeInt) && y.is_a?(SchemeInt) ? x.value < y.value : begin
              cmp = @interp.num_compare2(x, y, "<")
              !cmp.nil? && cmp < 0
            end
            frame.ip += instr.b unless truthy
          when Op::TestLeUp
            x = @stack.unsafe_fetch(base + instr.a); y = upvalue(frame, instr.c).get
            truthy = x.is_a?(SchemeInt) && y.is_a?(SchemeInt) ? x.value <= y.value : begin
              cmp = @interp.num_compare2(x, y, "<=")
              !cmp.nil? && cmp <= 0
            end
            frame.ip += instr.b unless truthy
          when Op::TestGtUp
            x = @stack.unsafe_fetch(base + instr.a); y = upvalue(frame, instr.c).get
            truthy = x.is_a?(SchemeInt) && y.is_a?(SchemeInt) ? x.value > y.value : begin
              cmp = @interp.num_compare2(x, y, ">")
              !cmp.nil? && cmp > 0
            end
            frame.ip += instr.b unless truthy
          when Op::TestGeUp
            x = @stack.unsafe_fetch(base + instr.a); y = upvalue(frame, instr.c).get
            truthy = x.is_a?(SchemeInt) && y.is_a?(SchemeInt) ? x.value >= y.value : begin
              cmp = @interp.num_compare2(x, y, ">=")
              !cmp.nil? && cmp >= 0
            end
            frame.ip += instr.b unless truthy
          when Op::TestEqUp
            x = @stack.unsafe_fetch(base + instr.a); y = upvalue(frame, instr.c).get
            truthy = x.is_a?(SchemeInt) && y.is_a?(SchemeInt) ? x.value == y.value : begin
              cmp = @interp.num_compare2(x, y, "=")
              !cmp.nil? && cmp == 0
            end
            frame.ip += instr.b unless truthy
          when Op::Closure
            @stack.unsafe_put(base + instr.a, make_closure(frame, frame.chunk.protos.unsafe_fetch(instr.b), instr.b))
          when Op::MakeCaseClosure
            clauses = Array(BytecodeClosure).new(instr.c) { |i| @stack.unsafe_fetch(base + instr.b + i).as(BytecodeClosure) }
            @stack.unsafe_put(base + instr.a, BytecodeCaseClosure.new(clauses, frame.root_env))
          when Op::Destructure
            exec_destructure(base, instr)
          when Op::ParamPush
            exec_param_push(base, instr)
          when Op::ParamPop
            @unwind_stack.pop.run
          when Op::PushHandler
            resume_ip = frame.ip + instr.b
            @handlers << GuardHandler.new(@depth, frame, @unwind_stack.size, instr.a, resume_ip)
          when Op::PopHandler
            @handlers.pop
          when Op::GuardReraise
            raise @pending_reraise || raise SchemeRuntimeError.new("internal: no pending exception to re-raise")
          when Op::Quasiquote
            value, _ = build_qq(frame.chunk.qq_templates.unsafe_fetch(instr.b), base + instr.c, 0)
            @stack.unsafe_put(base + instr.a, value)
          when Op::MakePromise
            @stack.unsafe_put(base + instr.a, SchemePromise.new(@stack.unsafe_fetch(base + instr.b)))
          when Op::HelperForm
            form = frame.chunk.consts.unsafe_fetch(instr.b).as(Cons)
            @stack.unsafe_put(base + instr.a, exec_helper_form(instr.c, form, frame.root_env))
          when Op::HelperFormLocal
            exec_helper_form_local(frame, base, instr)
          when Op::Call
            exec_call(frame, instr, tail: false)
            frame, base, instructions = refresh_frame
          when Op::TailCall
            result = exec_call(frame, instr, tail: true)
            return result unless result.nil?
            frame, base, instructions = refresh_frame
          when Op::CallGlobal
            exec_call_global(frame, instr, tail: false)
            frame, base, instructions = refresh_frame
          when Op::TailCallGlobal
            result = exec_call_global(frame, instr, tail: true)
            return result unless result.nil?
            frame, base, instructions = refresh_frame
          when Op::CallLocal
            exec_call_local(frame, instr, tail: false)
            frame, base, instructions = refresh_frame
          when Op::TailCallLocal
            result = exec_call_local(frame, instr, tail: true)
            return result unless result.nil?
            frame, base, instructions = refresh_frame
          when Op::CallUpval
            exec_call_upval(frame, instr, tail: false)
            frame, base, instructions = refresh_frame
          when Op::TailCallUpval
            result = exec_call_upval(frame, instr, tail: true)
            return result unless result.nil?
            frame, base, instructions = refresh_frame
          when Op::Return
            result = deliver_return(@stack.unsafe_fetch(base + instr.a))
            return result unless result.nil?
            frame, base, instructions = refresh_frame
          when Op::ReturnGlobal
            result = deliver_return(get_global_cached(frame, frame.ip - 1, instr.a))
            return result unless result.nil?
            frame, base, instructions = refresh_frame
          when Op::ReturnUpval
            result = deliver_return(upvalue(frame, instr.a).get)
            return result unless result.nil?
            frame, base, instructions = refresh_frame
          when Op::AddReturn, Op::SubReturn, Op::MulReturn
            # The Return-fused arithmetic trio (e.g. fib's inner
            # `(+ (fib ...) (fib ...))` in tail position) — inlined here for
            # the same reason as the base Op::Add arm above: skip exec_prim's
            # method call + second `case`, on one of the hottest ops there is.
            # Semantics are byte-for-byte exec_prim's; compile_prim_call only
            # ever emits these in tail position, so delivering unconditionally
            # is always correct. Kept as its own arm at the END of the chain
            # (comparison-Returns stay in exec_prim just below) so no pre-
            # existing arm's position in the comparison chain shifts.
            x = @stack.unsafe_fetch(base + instr.b); y = @stack.unsafe_fetch(base + instr.c)
            res = case instr.op
                  when Op::AddReturn
                    x.is_a?(SchemeInt) && y.is_a?(SchemeInt) ? (begin
                      SchemeInt.new(x.value + y.value)
                    rescue OverflowError
                      @interp.num_add(x, y, "+")
                    end) : @interp.num_add(x, y, "+")
                  when Op::SubReturn
                    x.is_a?(SchemeInt) && y.is_a?(SchemeInt) ? (begin
                      SchemeInt.new(x.value - y.value)
                    rescue OverflowError
                      @interp.num_sub(x, y, "-")
                    end) : @interp.num_sub(x, y, "-")
                  else # Op::MulReturn
                    x.is_a?(SchemeInt) && y.is_a?(SchemeInt) ? (begin
                      SchemeInt.new(x.value * y.value)
                    rescue OverflowError
                      @interp.num_mul(x, y, "*")
                    end) : @interp.num_mul(x, y, "*")
                  end
            @stack.unsafe_put(base + instr.a, res.as(SchemeValue))
            result = deliver_return(res.as(SchemeValue))
            return result unless result.nil?
            frame, base, instructions = refresh_frame
          when Op::NumLtReturn, Op::NumLeReturn,
               Op::NumGtReturn, Op::NumGeReturn, Op::NumEqReturn, Op::IsEqReturn
            # The comparison-Returns stay routed through exec_prim (rarer in
            # tail position than the arithmetic trio above). Own arm at the
            # END of the chain — see opcode.cr's AddReturn doc and the
            # execute/execute_sampled split comment for why appending (never
            # inserting mid-chain) matters here.
            exec_prim(frame, base, instr)
            result = deliver_return(@stack.unsafe_fetch(base + instr.a))
            return result unless result.nil?
            frame, base, instructions = refresh_frame
          when Op::Cxr
            # The whole (scheme cxr) accessor family (car/cdr/caar/.../cddddr)
            # fused into one op: operand c encodes the car/cdr chain as bits
            # (1=car, 0=cdr) applied LSB-first, terminated by a sentinel top bit
            # (see bytecode_compiler.cr's cxr_code). Fast-path while every step
            # lands on a pair; on the first non-pair, deopt to the real builtin
            # so its "<name>: expected pair" error keeps its own backtrace frame
            # + position (see cxr_deopt). Own arm at the END of the chain —
            # appending, never inserting mid-chain (see the AddReturn arm above /
            # doc/optimization.md).
            v = @stack.unsafe_fetch(base + instr.b)
            code = instr.c
            while code != 1
              unless v.is_a?(Cons)
                v = unary_prim_deopt(frame, instr)
                break
              end
              v = (code & 1) == 1 ? v.car : v.cdr
              code >>= 1
            end
            @stack.unsafe_put(base + instr.a, v)
          when Op::Abs
            # Fast-path a non-INT64_MIN integer inline; everything else (float,
            # rational, INT64_MIN overflow, non-number error) deopts to the abs
            # builtin. Own arm at the END of the chain (append-only).
            v = @stack.unsafe_fetch(base + instr.b)
            res = if v.is_a?(SchemeInt) && v.value != Int64::MIN
                    v.value < 0 ? SchemeInt.new(-v.value) : v
                  else
                    unary_prim_deopt(frame, instr)
                  end
            @stack.unsafe_put(base + instr.a, res)
          when Op::CmpZero
            # zero?/positive?/negative? — operand c selects the test. Fast-path
            # int and float inline; rational/complex/non-number deopt to the
            # builtin (which matches = / > / < against 0, including its errors).
            v = @stack.unsafe_fetch(base + instr.b)
            res = if v.is_a?(SchemeInt)
                    n = v.value
                    SchemeBool.of(instr.c == 0 ? n == 0 : (instr.c == 1 ? n > 0 : n < 0))
                  elsif v.is_a?(SchemeFloat)
                    f = v.value
                    SchemeBool.of(instr.c == 0 ? f == 0.0 : (instr.c == 1 ? f > 0.0 : f < 0.0))
                  else
                    unary_prim_deopt(frame, instr)
                  end
            @stack.unsafe_put(base + instr.a, res)
          when Op::TestIsEq
            # eq?'s fused compare+branch — unlike TestEq (numeric `=`), no int
            # fast path/fallback split is needed: scheme_eqv? is already a
            # cheap, allocation-free case dispatch that handles every
            # SchemeValue type (including two ints) in one call. Own arm at
            # the END of the chain — appending, never inserting mid-chain
            # (see the Cxr/Abs arms above / doc/optimization.md), even though
            # it's conceptually part of the TestEq family above.
            x = @stack.unsafe_fetch(base + instr.a); y = @stack.unsafe_fetch(base + instr.c)
            frame.ip += instr.b unless Scheme.scheme_eqv?(x, y)
          when Op::TestIsEqImm
            # c is always logically a SchemeInt (imm_operand? only ever bakes
            # an integer literal), and scheme_eqv? says a non-int is never
            # eqv? an int — so this needs no SchemeInt allocation or
            # fallback, just a direct int comparison.
            x = @stack.unsafe_fetch(base + instr.a)
            frame.ip += instr.b unless x.is_a?(SchemeInt) && x.value == instr.c.to_i64
          when Op::TestIsEqUp
            x = @stack.unsafe_fetch(base + instr.a); y = upvalue(frame, instr.c).get
            frame.ip += instr.b unless Scheme.scheme_eqv?(x, y)
          end
        rescue ex : SchemeExecutionLimitError
          # Sandboxing budgets must never be interceptable by guard — always
          # propagate.
          raise ex
        rescue ex : SchemeError
          result = handle_guarded_error(ex)
          return result unless result.nil?
          # handle_guarded_error unwound @depth to the matching guard's own
          # saved depth (arbitrary — not necessarily the frame active when
          # the error was raised), so the cached triplet must be re-derived
          # before the loop resumes, same as after any Call/Return above.
          frame, base, instructions = refresh_frame
        rescue ex : ContinuationInvoked | SchemeExit
          # Neither is a SchemeError (deliberately, so guard can never
          # intercept them — see errors.cr) — this VM instance's entire
          # `execute` is being abandoned (a captured continuation escaping
          # past it, or the program exiting), so every pending UnwindAction
          # (parameterize restores) must still run first, same as the no-
          # guard-found path above.
          drain_unwind_stack
          raise ex
        end
      end
    end
    {% end %}
    {% end %}

    # Dispatches to whichever execute* variant fits — checked once per
    # top-level entry (see the doc comment on `execute` above for why this
    # can't just be a per-instruction check instead).
    private def sampling_execute : SchemeValue
      sampled = !@interp.sample_interval.nil?
      limited = !@interp.max_steps.nil?
      if sampled
        limited ? execute_sampled_limited : execute_sampled
      else
        limited ? execute_limited : execute
      end
    end

    # Looks up the innermost installed guard, if any, and jumps execution
    # back to its clause-checking code — or re-raises for an outer
    # catcher/the VM's own caller if no guard is currently installed.
    # Implements guard's clause semantics (see compile_guard/
    # compile_guard_clauses) via an explicit handler stack rather than
    # Crystal's own begin/rescue, since ordinary Scheme calls in this VM
    # don't create new Crystal stack frames to hang a rescue off of.
    private def handle_guarded_error(ex : SchemeError) : SchemeValue?
      handler = @handlers.pop?
      unless handler
        # No guard anywhere in scope — this SchemeError is escaping this
        # entire `execute` invocation, so every pending UnwindAction
        # (parameterize restores) must still run before it does, matching
        # Crystal's own `ensure` firing all the way out of an uncaught
        # exception.
        drain_unwind_stack
        raise ex
      end
      while @unwind_stack.size > handler.unwind_mark
        @unwind_stack.pop.run
      end
      (handler.depth...@depth).each { |d| close_upvalues(@frames[d]) }
      @depth = handler.depth
      condition = ex.payload || SchemeRecord.new(CONDITION_TYPE, [SchemeStr.new(ex.message || "error"), NIL] of SchemeValue).as(SchemeValue)
      @stack.unsafe_put(handler.frame.base + handler.condition_reg, condition)
      @pending_reraise = ex
      handler.frame.ip = handler.resume_ip
      nil
    end

    private def drain_unwind_stack : Nil
      while @unwind_stack.size > 0
        @unwind_stack.pop.run
      end
    end

    private def falsy?(val : SchemeValue) : Bool
      val.is_a?(SchemeBool) && !val.value?
    end

    # Calls the primitive's underlying helper directly (same bounds-check/
    # error-message conventions the real builtin uses) rather than routing
    # through the generic Builtin/apply path (arity check, args-array alloc,
    # call-stack frame push/pop). That indirection is a real, measurable cost
    # in arithmetic/comparison-heavy hot loops (fib/sum-to/vector-sum) — going
    # straight to the direct helpers avoids it. `d` (the const-pool index of
    # the original Builtin) is unused here now, kept only for a possible future
    # error-message/introspection need.
    #
    # Add/Sub/Mul/comparisons additionally fast-path the SchemeInt/SchemeInt
    # case directly (computing on the raw Int64s, no proc/closure allocation
    # or numeric-tower rank dispatch) since Interpreter#num_add et al. build
    # THREE capturing proc literals per call (int/rational/float ops passed
    # to num_binop3) even when every operand is already a plain fixnum — a
    # real, measurable cost in an integer-heavy hot loop like fib/sum-to.
    # Anything not both-SchemeInt (floats, rationals, complex, or an
    # overflowing add/sub/mul) falls back to the exact same general helpers,
    # so semantics/error messages are unchanged.
    # ameba:disable Metrics/CyclomaticComplexity
    private def exec_prim(frame : CallFrame, base : Int32, instr : Instruction) : Nil
      # Raw buffer pointer, not @stack itself: Pointer#[]/#[]= are unchecked
      # (unlike Array#[]/#[]=), giving the same bounds-check-free register
      # access the main dispatch loop already uses via unsafe_fetch/unsafe_put.
      # Safe because nothing exec_prim calls ever grows @stack (only
      # dispatch_call/run/call do, via ensure_stack_size), so this pointer
      # stays valid for the whole method — the register indices are all
      # compiler-generated and known in-range, exactly as elsewhere.
      regs = @stack.to_unsafe
      case instr.op
      when Op::Add, Op::AddReturn
        x = regs[base + instr.b]; y = regs[base + instr.c]
        regs[base + instr.a] = if x.is_a?(SchemeInt) && y.is_a?(SchemeInt)
                                 begin
                                   SchemeInt.new(x.value + y.value)
                                 rescue OverflowError
                                   @interp.num_add(x, y, "+")
                                 end
                               else
                                 @interp.num_add(x, y, "+")
                               end
      when Op::Sub, Op::SubReturn
        x = regs[base + instr.b]; y = regs[base + instr.c]
        regs[base + instr.a] = if x.is_a?(SchemeInt) && y.is_a?(SchemeInt)
                                 begin
                                   SchemeInt.new(x.value - y.value)
                                 rescue OverflowError
                                   @interp.num_sub(x, y, "-")
                                 end
                               else
                                 @interp.num_sub(x, y, "-")
                               end
      when Op::Mul, Op::MulReturn
        x = regs[base + instr.b]; y = regs[base + instr.c]
        regs[base + instr.a] = if x.is_a?(SchemeInt) && y.is_a?(SchemeInt)
                                 begin
                                   SchemeInt.new(x.value * y.value)
                                 rescue OverflowError
                                   @interp.num_mul(x, y, "*")
                                 end
                               else
                                 @interp.num_mul(x, y, "*")
                               end
      when Op::NumLt, Op::NumLtReturn
        x = regs[base + instr.b]; y = regs[base + instr.c]
        regs[base + instr.a] = if x.is_a?(SchemeInt) && y.is_a?(SchemeInt)
                                 SchemeBool.of(x.value < y.value)
                               else
                                 cmp = @interp.num_compare2(x, y, "<")
                                 SchemeBool.of(!cmp.nil? && cmp < 0)
                               end
      when Op::NumLe, Op::NumLeReturn
        x = regs[base + instr.b]; y = regs[base + instr.c]
        regs[base + instr.a] = if x.is_a?(SchemeInt) && y.is_a?(SchemeInt)
                                 SchemeBool.of(x.value <= y.value)
                               else
                                 cmp = @interp.num_compare2(x, y, "<=")
                                 SchemeBool.of(!cmp.nil? && cmp <= 0)
                               end
      when Op::NumGt, Op::NumGtReturn
        x = regs[base + instr.b]; y = regs[base + instr.c]
        regs[base + instr.a] = if x.is_a?(SchemeInt) && y.is_a?(SchemeInt)
                                 SchemeBool.of(x.value > y.value)
                               else
                                 cmp = @interp.num_compare2(x, y, ">")
                                 SchemeBool.of(!cmp.nil? && cmp > 0)
                               end
      when Op::NumGe, Op::NumGeReturn
        x = regs[base + instr.b]; y = regs[base + instr.c]
        regs[base + instr.a] = if x.is_a?(SchemeInt) && y.is_a?(SchemeInt)
                                 SchemeBool.of(x.value >= y.value)
                               else
                                 cmp = @interp.num_compare2(x, y, ">=")
                                 SchemeBool.of(!cmp.nil? && cmp >= 0)
                               end
      when Op::NumEq, Op::NumEqReturn
        x = regs[base + instr.b]; y = regs[base + instr.c]
        regs[base + instr.a] = if x.is_a?(SchemeInt) && y.is_a?(SchemeInt)
                                 SchemeBool.of(x.value == y.value)
                               else
                                 cmp = @interp.num_compare2(x, y, "=")
                                 SchemeBool.of(!cmp.nil? && cmp == 0)
                               end
      when Op::AddImm
        x = regs[base + instr.b]
        imm = SchemeInt.new(instr.c.to_i64)
        regs[base + instr.a] = if x.is_a?(SchemeInt)
                                 begin
                                   SchemeInt.new(x.value + instr.c.to_i64)
                                 rescue OverflowError
                                   @interp.num_add(x, imm, "+")
                                 end
                               else
                                 @interp.num_add(x.as(SchemeValue), imm, "+")
                               end
      when Op::SubImm
        x = regs[base + instr.b]
        imm = SchemeInt.new(instr.c.to_i64)
        regs[base + instr.a] = if x.is_a?(SchemeInt)
                                 begin
                                   SchemeInt.new(x.value - instr.c.to_i64)
                                 rescue OverflowError
                                   @interp.num_sub(x, imm, "-")
                                 end
                               else
                                 @interp.num_sub(x.as(SchemeValue), imm, "-")
                               end
      when Op::MulImm
        x = regs[base + instr.b]
        imm = SchemeInt.new(instr.c.to_i64)
        regs[base + instr.a] = if x.is_a?(SchemeInt)
                                 begin
                                   SchemeInt.new(x.value * instr.c.to_i64)
                                 rescue OverflowError
                                   @interp.num_mul(x, imm, "*")
                                 end
                               else
                                 @interp.num_mul(x.as(SchemeValue), imm, "*")
                               end
      when Op::NumLtImm
        x = regs[base + instr.b]
        regs[base + instr.a] = if x.is_a?(SchemeInt)
                                 SchemeBool.of(x.value < instr.c.to_i64)
                               else
                                 cmp = @interp.num_compare2(x.as(SchemeValue), SchemeInt.new(instr.c.to_i64), "<")
                                 SchemeBool.of(!cmp.nil? && cmp < 0)
                               end
      when Op::NumLeImm
        x = regs[base + instr.b]
        regs[base + instr.a] = if x.is_a?(SchemeInt)
                                 SchemeBool.of(x.value <= instr.c.to_i64)
                               else
                                 cmp = @interp.num_compare2(x.as(SchemeValue), SchemeInt.new(instr.c.to_i64), "<=")
                                 SchemeBool.of(!cmp.nil? && cmp <= 0)
                               end
      when Op::NumGtImm
        x = regs[base + instr.b]
        regs[base + instr.a] = if x.is_a?(SchemeInt)
                                 SchemeBool.of(x.value > instr.c.to_i64)
                               else
                                 cmp = @interp.num_compare2(x.as(SchemeValue), SchemeInt.new(instr.c.to_i64), ">")
                                 SchemeBool.of(!cmp.nil? && cmp > 0)
                               end
      when Op::NumGeImm
        x = regs[base + instr.b]
        regs[base + instr.a] = if x.is_a?(SchemeInt)
                                 SchemeBool.of(x.value >= instr.c.to_i64)
                               else
                                 cmp = @interp.num_compare2(x.as(SchemeValue), SchemeInt.new(instr.c.to_i64), ">=")
                                 SchemeBool.of(!cmp.nil? && cmp >= 0)
                               end
      when Op::NumEqImm
        x = regs[base + instr.b]
        regs[base + instr.a] = if x.is_a?(SchemeInt)
                                 SchemeBool.of(x.value == instr.c.to_i64)
                               else
                                 cmp = @interp.num_compare2(x.as(SchemeValue), SchemeInt.new(instr.c.to_i64), "=")
                                 SchemeBool.of(!cmp.nil? && cmp == 0)
                               end
      when Op::AddUp
        x = regs[base + instr.b]
        y = upvalue(frame, instr.c).get
        regs[base + instr.a] = if x.is_a?(SchemeInt) && y.is_a?(SchemeInt)
                                 begin
                                   SchemeInt.new(x.value + y.value)
                                 rescue OverflowError
                                   @interp.num_add(x, y, "+")
                                 end
                               else
                                 @interp.num_add(x, y, "+")
                               end
      when Op::SubUp
        x = regs[base + instr.b]
        y = upvalue(frame, instr.c).get
        regs[base + instr.a] = if x.is_a?(SchemeInt) && y.is_a?(SchemeInt)
                                 begin
                                   SchemeInt.new(x.value - y.value)
                                 rescue OverflowError
                                   @interp.num_sub(x, y, "-")
                                 end
                               else
                                 @interp.num_sub(x, y, "-")
                               end
      when Op::MulUp
        x = regs[base + instr.b]
        y = upvalue(frame, instr.c).get
        regs[base + instr.a] = if x.is_a?(SchemeInt) && y.is_a?(SchemeInt)
                                 begin
                                   SchemeInt.new(x.value * y.value)
                                 rescue OverflowError
                                   @interp.num_mul(x, y, "*")
                                 end
                               else
                                 @interp.num_mul(x, y, "*")
                               end
      when Op::NumLtUp
        x = regs[base + instr.b]
        y = upvalue(frame, instr.c).get
        regs[base + instr.a] = if x.is_a?(SchemeInt) && y.is_a?(SchemeInt)
                                 SchemeBool.of(x.value < y.value)
                               else
                                 cmp = @interp.num_compare2(x, y, "<")
                                 SchemeBool.of(!cmp.nil? && cmp < 0)
                               end
      when Op::NumLeUp
        x = regs[base + instr.b]
        y = upvalue(frame, instr.c).get
        regs[base + instr.a] = if x.is_a?(SchemeInt) && y.is_a?(SchemeInt)
                                 SchemeBool.of(x.value <= y.value)
                               else
                                 cmp = @interp.num_compare2(x, y, "<=")
                                 SchemeBool.of(!cmp.nil? && cmp <= 0)
                               end
      when Op::NumGtUp
        x = regs[base + instr.b]
        y = upvalue(frame, instr.c).get
        regs[base + instr.a] = if x.is_a?(SchemeInt) && y.is_a?(SchemeInt)
                                 SchemeBool.of(x.value > y.value)
                               else
                                 cmp = @interp.num_compare2(x, y, ">")
                                 SchemeBool.of(!cmp.nil? && cmp > 0)
                               end
      when Op::NumGeUp
        x = regs[base + instr.b]
        y = upvalue(frame, instr.c).get
        regs[base + instr.a] = if x.is_a?(SchemeInt) && y.is_a?(SchemeInt)
                                 SchemeBool.of(x.value >= y.value)
                               else
                                 cmp = @interp.num_compare2(x, y, ">=")
                                 SchemeBool.of(!cmp.nil? && cmp >= 0)
                               end
      when Op::NumEqUp
        x = regs[base + instr.b]
        y = upvalue(frame, instr.c).get
        regs[base + instr.a] = if x.is_a?(SchemeInt) && y.is_a?(SchemeInt)
                                 SchemeBool.of(x.value == y.value)
                               else
                                 cmp = @interp.num_compare2(x, y, "=")
                                 SchemeBool.of(!cmp.nil? && cmp == 0)
                               end
      when Op::VecLen
        arr = @interp.vector_arg(regs[base + instr.b], "vector-length")
        regs[base + instr.a] = SchemeInt.new(arr.size.to_i64)
      when Op::VecRef
        arr = @interp.vector_arg(regs[base + instr.b], "vector-ref")
        i = @interp.vector_index_arg(regs[base + instr.c], "vector-ref")
        raise SchemeRuntimeError.new("vector-ref: index #{i} out of range") if i < 0 || i >= arr.size
        regs[base + instr.a] = arr[i]
      when Op::VecSet
        arr = @interp.vector_arg(regs[base + instr.a], "vector-set!")
        i = @interp.vector_index_arg(regs[base + instr.b], "vector-set!")
        raise SchemeRuntimeError.new("vector-set!: index #{i} out of range") if i < 0 || i >= arr.size
        arr[i] = regs[base + instr.c]
      when Op::VecRefImm
        arr = @interp.vector_arg(regs[base + instr.b], "vector-ref")
        i = instr.c
        raise SchemeRuntimeError.new("vector-ref: index #{i} out of range") if i < 0 || i >= arr.size
        regs[base + instr.a] = arr[i]
      when Op::VecSetImm
        arr = @interp.vector_arg(regs[base + instr.a], "vector-set!")
        i = instr.b
        raise SchemeRuntimeError.new("vector-set!: index #{i} out of range") if i < 0 || i >= arr.size
        arr[i] = regs[base + instr.c]
      when Op::StrRef
        sv = regs[base + instr.b]
        raise SchemeRuntimeError.new("string-ref: expected string, got #{sv.write_string}") unless sv.is_a?(SchemeStr)
        idx = @interp.int_arg(regs[base + instr.c], "string-ref")
        raise SchemeRuntimeError.new("string-ref: index out of range") if idx < 0 || idx >= sv.value.size
        regs[base + instr.a] = SchemeChar.new(sv.value[idx.to_i])
      when Op::StrSet
        sv = regs[base + instr.a]
        raise SchemeRuntimeError.new("string-set!: expected string, got #{sv.write_string}") unless sv.is_a?(SchemeStr)
        idx = @interp.int_arg(regs[base + instr.b], "string-set!").to_i32
        chv = regs[base + instr.c]
        raise SchemeRuntimeError.new("string-set!: expected char, got #{chv.write_string}") unless chv.is_a?(SchemeChar)
        chars = sv.value.chars
        raise SchemeRuntimeError.new("string-set!: index out of range") if idx < 0 || idx >= chars.size
        chars[idx] = chv.value
        sv.value = chars.join
      when Op::BvRef
        bytes = @interp.blob_arg(regs[base + instr.b], "bytevector-u8-ref")
        idx = @interp.int_arg(regs[base + instr.c], "bytevector-u8-ref")
        raise SchemeRuntimeError.new("bytevector-u8-ref: index out of range") if idx < 0 || idx >= bytes.size
        regs[base + instr.a] = SchemeInt.new(bytes[idx].to_i64)
      when Op::BvSet
        bytes = @interp.blob_arg(regs[base + instr.a], "bytevector-u8-set!")
        idx = @interp.int_arg(regs[base + instr.b], "bytevector-u8-set!")
        b = @interp.byte_arg(regs[base + instr.c], "bytevector-u8-set!")
        raise SchemeRuntimeError.new("bytevector-u8-set!: index out of range") if idx < 0 || idx >= bytes.size
        bytes[idx] = b
      when Op::StrRefImm
        sv = regs[base + instr.b]
        raise SchemeRuntimeError.new("string-ref: expected string, got #{sv.write_string}") unless sv.is_a?(SchemeStr)
        idx = instr.c
        raise SchemeRuntimeError.new("string-ref: index out of range") if idx < 0 || idx >= sv.value.size
        regs[base + instr.a] = SchemeChar.new(sv.value[idx])
      when Op::StrSetImm
        sv = regs[base + instr.a]
        raise SchemeRuntimeError.new("string-set!: expected string, got #{sv.write_string}") unless sv.is_a?(SchemeStr)
        idx = instr.b
        chv = regs[base + instr.c]
        raise SchemeRuntimeError.new("string-set!: expected char, got #{chv.write_string}") unless chv.is_a?(SchemeChar)
        chars = sv.value.chars
        raise SchemeRuntimeError.new("string-set!: index out of range") if idx < 0 || idx >= chars.size
        chars[idx] = chv.value
        sv.value = chars.join
      when Op::BvRefImm
        bytes = @interp.blob_arg(regs[base + instr.b], "bytevector-u8-ref")
        idx = instr.c
        raise SchemeRuntimeError.new("bytevector-u8-ref: index out of range") if idx < 0 || idx >= bytes.size
        regs[base + instr.a] = SchemeInt.new(bytes[idx].to_i64)
      when Op::BvSetImm
        bytes = @interp.blob_arg(regs[base + instr.a], "bytevector-u8-set!")
        idx = instr.b
        b = @interp.byte_arg(regs[base + instr.c], "bytevector-u8-set!")
        raise SchemeRuntimeError.new("bytevector-u8-set!: index out of range") if idx < 0 || idx >= bytes.size
        bytes[idx] = b
      when Op::VecLenUp
        arr = @interp.vector_arg(upvalue(frame, instr.b).get, "vector-length")
        regs[base + instr.a] = SchemeInt.new(arr.size.to_i64)
      when Op::VecRefUp
        arr = @interp.vector_arg(upvalue(frame, instr.b).get, "vector-ref")
        i = @interp.vector_index_arg(regs[base + instr.c], "vector-ref")
        raise SchemeRuntimeError.new("vector-ref: index #{i} out of range") if i < 0 || i >= arr.size
        regs[base + instr.a] = arr[i]
      when Op::VecSetUp
        obj = upvalue(frame, instr.a).get
        arr = @interp.vector_arg(obj, "vector-set!")
        i = @interp.vector_index_arg(regs[base + instr.b], "vector-set!")
        raise SchemeRuntimeError.new("vector-set!: index #{i} out of range") if i < 0 || i >= arr.size
        arr[i] = regs[base + instr.c]
        regs[base + instr.d] = obj
      when Op::StrRefUp
        sv = upvalue(frame, instr.b).get
        raise SchemeRuntimeError.new("string-ref: expected string, got #{sv.write_string}") unless sv.is_a?(SchemeStr)
        idx = @interp.int_arg(regs[base + instr.c], "string-ref")
        raise SchemeRuntimeError.new("string-ref: index out of range") if idx < 0 || idx >= sv.value.size
        regs[base + instr.a] = SchemeChar.new(sv.value[idx.to_i])
      when Op::StrSetUp
        sv = upvalue(frame, instr.a).get
        raise SchemeRuntimeError.new("string-set!: expected string, got #{sv.write_string}") unless sv.is_a?(SchemeStr)
        idx = @interp.int_arg(regs[base + instr.b], "string-set!").to_i32
        chv = regs[base + instr.c]
        raise SchemeRuntimeError.new("string-set!: expected char, got #{chv.write_string}") unless chv.is_a?(SchemeChar)
        chars = sv.value.chars
        raise SchemeRuntimeError.new("string-set!: index out of range") if idx < 0 || idx >= chars.size
        chars[idx] = chv.value
        sv.value = chars.join
        regs[base + instr.d] = sv
      when Op::BvRefUp
        bytes = @interp.blob_arg(upvalue(frame, instr.b).get, "bytevector-u8-ref")
        idx = @interp.int_arg(regs[base + instr.c], "bytevector-u8-ref")
        raise SchemeRuntimeError.new("bytevector-u8-ref: index out of range") if idx < 0 || idx >= bytes.size
        regs[base + instr.a] = SchemeInt.new(bytes[idx].to_i64)
      when Op::BvSetUp
        obj = upvalue(frame, instr.a).get
        bytes = @interp.blob_arg(obj, "bytevector-u8-set!")
        idx = @interp.int_arg(regs[base + instr.b], "bytevector-u8-set!")
        b = @interp.byte_arg(regs[base + instr.c], "bytevector-u8-set!")
        raise SchemeRuntimeError.new("bytevector-u8-set!: index out of range") if idx < 0 || idx >= bytes.size
        bytes[idx] = b
        regs[base + instr.d] = obj
      when Op::Cons
        regs[base + instr.a] = Cons.new(regs[base + instr.b], regs[base + instr.c])
      when Op::Not
        regs[base + instr.a] = SchemeBool.of(!Scheme.truthy?(regs[base + instr.b]))
      when Op::IsNull
        regs[base + instr.a] = SchemeBool.of(regs[base + instr.b].is_a?(SchemeNil))
      when Op::IsPair
        regs[base + instr.a] = SchemeBool.of(regs[base + instr.b].is_a?(Cons))
      when Op::IsEq, Op::IsEqReturn
        regs[base + instr.a] = SchemeBool.of(Scheme.scheme_eqv?(regs[base + instr.b], regs[base + instr.c]))
      when Op::IsEqImm
        # c is always logically a SchemeInt (imm_operand? only ever bakes an
        # integer literal) — same reasoning as TestIsEqImm above.
        x = regs[base + instr.b]
        regs[base + instr.a] = SchemeBool.of(x.is_a?(SchemeInt) && x.value == instr.c.to_i64)
      when Op::IsEqUp
        x = regs[base + instr.b]
        y = upvalue(frame, instr.c).get
        regs[base + instr.a] = SchemeBool.of(Scheme.scheme_eqv?(x, y))
      end
    end

    private def const_name(frame : CallFrame, idx : Int32) : String
      frame.chunk.consts.unsafe_fetch(idx).as(SchemeSym).name
    end

    # Slow path shared by the fused unary prims (Op::Cxr/Op::Abs/Op::CmpZero):
    # fall back to the original Builtin (const-pool index in operand `d`)
    # applied to the source value (register `b`) via the generic apply path,
    # which pushes a properly-named/positioned backtrace Frame and computes the
    # exact result/error the builtin would — so fusing never changes behavior on
    # the cases the fast path punts (non-pair for cxr; float/rational/overflow/
    # non-number for abs/cmp-zero). Returns the builtin's value (which for the
    # cxr non-pair case is always an error raise).
    private def unary_prim_deopt(frame : CallFrame, instr : Instruction) : SchemeValue
      builtin = frame.chunk.consts.unsafe_fetch(instr.d)
      src = @stack.unsafe_fetch(frame.base + instr.b)
      pos = frame.chunk.positions[frame.ip - 1]?
      @interp.current_pos = pos if pos
      @interp.apply(builtin, [src] of SchemeValue, pos)
    end

    # Inline-caches a GetGlobal site's resolved value keyed on the global
    # env's version — a hot recursive call like `(fib (- n 1))` references
    # the global `fib`
    # on every single invocation, so skipping the Env hash lookup while
    # nothing has (re)defined it at top level matters a lot in practice.
    private def get_global_cached(frame : CallFrame, instr_idx : Int32, const_idx : Int32) : SchemeValue
      # Bounds-check-free: `instr_idx` is always frame.ip - 1 for the
      # GetGlobal/CallGlobal-family instruction currently executing, and
      # Chunk#emit keeps both cache arrays 1:1-sized with `instructions` (a
      # slot appended for every instruction, not just GetGlobal-family ones)
      # — so instr_idx is provably < both arrays' size, same reasoning as
      # `top_frame`'s @frames.unsafe_fetch.
      versions = frame.chunk.global_cache_versions
      values = frame.chunk.global_cache_values
      if versions.unsafe_fetch(instr_idx) == frame.root_env.version
        return values.unsafe_fetch(instr_idx).not_nil!
      end
      value = frame.root_env.get(const_name(frame, const_idx))
      values.unsafe_put(instr_idx, value)
      versions.unsafe_put(instr_idx, frame.root_env.version)
      value
    end

    private def closure_of(frame : CallFrame) : BytecodeClosure
      frame.closure || raise SchemeRuntimeError.new("internal: upvalue op in a frame with no closure")
    end

    # `frame`'s own closure's `idx`th upvalue. Bounds-check-free: `idx` is
    # always an upvalue index BytecodeCompiler resolved against THIS
    # closure's own upvalue list (a GetUpval/SetUpval/Closure-capture/*Up-
    # family operand, or a call-family op's own callee upvalue index), so
    # it's provably < upvalues.size — same reasoning as `top_frame`'s
    # @frames.unsafe_fetch.
    private def upvalue(frame : CallFrame, idx : Int32) : Upvalue
      closure_of(frame).upvalues.unsafe_fetch(idx)
    end

    # Closes every Upvalue opened against `frame`'s own registers — must run
    # before that frame's stack region (and its pooled CallFrame object) can
    # be reused by a later call: a TailCall reusing this exact base, or a
    # future push at this same depth once the frame has been popped. A
    # no-op (common case) for any frame that never had a Closure instruction
    # execute against it.
    private def close_upvalues(frame : CallFrame) : Nil
      frame.opened_upvalues.try(&.each(&.close!))
    end

    # Delivers a Return value and pops the current activation (@depth -= 1;
    # the popped CallFrame object stays in the `@frames` pool for reuse by a
    # future call at that same depth). Returns nil ("keep running") after
    # writing the value into the new top frame's `return_reg`, or — if this
    # was the outermost frame — the value itself, signaling the VM's overall
    # result.
    private def deliver_return(val : SchemeValue) : SchemeValue?
      finished = top_frame
      close_upvalues(finished)
      @interp.pop_frame if finished.owns_interp_frame
      @depth -= 1
      if @depth == 0
        val
      else
        if reg = finished.return_reg
          @stack.unsafe_put(top_frame.base + reg, val)
        end
        nil
      end
    end

    # `proto_idx` is `proto`'s own slot within `frame.chunk.protos` — used
    # only to key the zero-upvalue memoization below (see
    # BytecodeClosure#cached_zero_upvalue_closure's own doc comment for why
    # caching there, keyed by this, is sound). A lambda literal with zero
    # captured upvalues is re-evaluated with an identical result every
    # time (no free variables to vary), so — as long as the CURRENTLY
    # RUNNING closure itself (`frame.closure`) doesn't change, which holds
    # across every iteration of a tail-recursive loop reusing the same
    # frame — the very first instance created is safe to keep reusing
    # instead of allocating a fresh, immediately-identical one on every
    # single execution (the actual cost this avoids: hot loops evaluating
    # a lambda literal, e.g. as a default-value thunk, once per iteration).
    # Skipped for a top-level (non-closure) frame — `frame.closure` is nil
    # there and there's no owning instance to cache the memo on; those
    # aren't normally hot loops anyway.
    private def make_closure(frame : CallFrame, proto : Chunk, proto_idx : Int32) : BytecodeClosure
      if proto.upvalues.empty? && (owner = frame.closure)
        return owner.cached_zero_upvalue_closure(proto_idx) { BytecodeClosure.new(proto, [] of Upvalue, frame.root_env) }
      end
      upvalues = proto.upvalues.map do |desc|
        if desc.from_parent_local
          upvalue = Upvalue.new(@stack, frame.base + desc.index)
          (frame.opened_upvalues ||= [] of Upvalue) << upvalue
          upvalue
        else
          closure_of(frame).upvalues[desc.index]
        end
      end
      BytecodeClosure.new(proto, upvalues, frame.root_env)
    end

    # Backs define-values/let-values/let*-values: `src` (a producer's
    # result, possibly a SchemeValues from multiple-value-returning code)
    # unpacks into dst[dst_base..dst_base+fixed) (plus a rest list at
    # dst_base+fixed if `has_rest`), raising if the count doesn't match —
    # same shape as bind_args, but the source is one already-computed value
    # instead of a fresh call's argument registers.
    private def exec_destructure(base : Int32, instr : Instruction) : Nil
      src = @stack.unsafe_fetch(base + instr.a)
      vals = src.is_a?(SchemeValues) ? src.items : [src]
      fixed = instr.c
      has_rest = instr.d != 0
      if has_rest
        raise SchemeRuntimeError.new("values: expected at least #{fixed} value(s), got #{vals.size}") if vals.size < fixed
      else
        raise SchemeRuntimeError.new("values: expected #{fixed} value(s), got #{vals.size}") if vals.size != fixed
      end
      dst_base = base + instr.b
      fixed.times { |i| @stack.unsafe_put(dst_base + i, vals[i]) }
      return unless has_rest
      rest_list : SchemeValue = NIL
      (vals.size - 1).downto(fixed) { |i| rest_list = Cons.new(vals[i], rest_list) }
      @stack.unsafe_put(dst_base + fixed, rest_list)
    end

    # Reconstructs a quasiquoted datum from its QQTemplate (QQConst/QQHole/
    # QQList/QQVector/QQSpliceItem), with each hole pulling its pre-evaluated
    # value from `@stack.unsafe_fetch(hole_base + idx)` (idx threaded through
    # and returned alongside the built value) — see compile_quasiquote/
    # compile_qq_holes for why the traversal order here must match exactly
    # how those compiled each hole into its own contiguous register.
    private def build_qq(t : QQTemplate, hole_base : Int32, idx : Int32) : {SchemeValue, Int32}
      case t
      when QQConst
        {t.value, idx}
      when QQHole
        {@stack.unsafe_fetch(hole_base + idx), idx + 1}
      when QQList
        items = [] of SchemeValue
        cur = idx
        t.items.each do |item|
          if item.is_a?(QQSpliceItem)
            Scheme.list_to_a(@stack.unsafe_fetch(hole_base + cur)).each { |x| items << x }
            cur += 1
          else
            value, cur = build_qq(item, hole_base, cur)
            items << value
          end
        end
        tail_value, cur = build_qq(t.tail, hole_base, cur)
        {Scheme.a_to_list(items, tail_value), cur}
      when QQVector
        items = [] of SchemeValue
        cur = idx
        t.items.each do |item|
          if item.is_a?(QQSpliceItem)
            Scheme.list_to_a(@stack.unsafe_fetch(hole_base + cur)).each { |x| items << x }
            cur += 1
          else
            value, cur = build_qq(item, hole_base, cur)
            items << value
          end
        end
        {SchemeVector.new(items), cur}
      else # QQSpliceItem in non-list context (shouldn't occur)
        {NIL.as(SchemeValue), idx}
      end
    end

    # import/define-library/define-record-type/define-syntax/defmacro —
    # against the current frame's root_env (see compile_helper_form: only
    # ever compiled at the top level of whatever env this frame targets).
    private def exec_helper_form(kind : Int32, form : Cons, root_env : Env) : SchemeValue
      case kind
      when 0 then @interp.eval_import(form, root_env)
      when 1 then @interp.eval_define_library(form, root_env)
      when 2 then @interp.eval_define_record_type(form, root_env)
      when 3 then @interp.eval_define_syntax(form, root_env)
      else        @interp.eval_defmacro(form, root_env)
      end
    end

    # A define-record-type used INSIDE a function body (see
    # compile_helper_form) — runs against a throwaway scratch Env (each
    # call must produce a genuinely fresh, disjoint SchemeRecordType, so
    # there's no persistent env to target the way top-level HelperForm
    # ops have), then copies its produced bindings, in
    # Scheme.record_type_names' order, out into the registers the
    # compiler pre-declared for them.
    private def exec_helper_form_local(frame : CallFrame, base : Int32, instr : Instruction) : Nil
      form = frame.chunk.consts.unsafe_fetch(instr.b).as(Cons)
      scratch_env = Env.new
      @interp.eval_define_record_type(form, scratch_env)
      names = Scheme.record_type_names(form).not_nil!
      names.each_with_index { |name, i| @stack.unsafe_put(base + instr.a + i, scratch_env.get(name)) }
    end

    # (parameterize ((param val)...) body...): for each pair, apply the
    # parameter's converter (if any) to val, save the CURRENT value, then
    # set the new one — a strict two-pass order (compute every converted
    # newval first, THEN save, THEN assign) so a converter can't observe a
    # partially-updated set of parameters.
    private def exec_param_push(base : Int32, instr : Instruction) : Nil
      count = instr.c
      param_base = base + instr.a
      newval_base = base + instr.b
      params = Array(SchemeParameter).new(count)
      newvals = Array(SchemeValue).new(count)
      count.times do |i|
        par = @stack.unsafe_fetch(param_base + i)
        raise SchemeRuntimeError.new("parameterize: expected a parameter object") unless par.is_a?(SchemeParameter)
        params << par
        raw = @stack.unsafe_fetch(newval_base + i)
        conv = par.converter
        newvals << (conv ? @interp.apply(conv, [raw]) : raw)
      end
      saved = params.map(&.value)
      params.each_with_index { |par, i| par.value = newvals[i] }
      @unwind_stack << ParamRestoreAction.new(params, saved)
    end

    # Used only by VM#call (Interpreter#apply's bridge from a builtin calling
    # back into a closure), where args already arrive as a plain Array.
    private def bind_args_from_array(chunk : Chunk, args : Array(SchemeValue), dst_base : Int32,
                                     dst : Array(SchemeValue)) : Nil
      bind_args(chunk, args.size, dst_base, dst) { |i| args[i] }
    end

    # Binds a call's arguments into the new frame's registers (dst[dst_base
    # ..]) — `src` fetches argument `i`, either from the caller's own
    # register window (the common BytecodeClosure-calling-BytecodeClosure
    # path, no intermediate Array) or from a plain Array (VM#call's bridge
    # from Interpreter#apply).
    private def bind_args(chunk : Chunk, nargs : Int32, dst_base : Int32, dst : Array(SchemeValue), & : Int32 -> SchemeValue) : Nil
      fixed = chunk.param_count
      if chunk.has_rest?
        if nargs < fixed
          raise SchemeRuntimeError.new("#{chunk.name}: expected at least #{fixed} argument(s), got #{nargs}")
        end
        fixed.times { |i| dst[dst_base + i] = yield i }
        rest_list : SchemeValue = NIL
        (nargs - 1).downto(fixed) { |i| rest_list = Cons.new(yield(i), rest_list) }
        dst[dst_base + fixed] = rest_list
      else
        if nargs != fixed
          raise SchemeRuntimeError.new("#{chunk.name}: expected #{fixed} argument(s), got #{nargs}")
        end
        fixed.times { |i| dst[dst_base + i] = yield i }
      end
    end

    # Op::Call / Op::TailCall — the callee sits in register `a`.
    private def exec_call(frame : CallFrame, instr : Instruction, tail : Bool) : SchemeValue?
      dispatch_call(frame, instr, @stack.unsafe_fetch(frame.base + instr.a), tail)
    end

    # Op::CallGlobal / Op::TailCallGlobal — the callee is a global, resolved
    # from this instruction's own inline cache (same fast path + redefinition
    # safety as GetGlobal), NOT read from register `a`.
    private def exec_call_global(frame : CallFrame, instr : Instruction, tail : Bool) : SchemeValue?
      dispatch_call(frame, instr, get_global_cached(frame, frame.ip - 1, instr.d), tail)
    end

    # Op::CallLocal / Op::TailCallLocal — the callee is a local, in register
    # `d` (distinct from the arg anchor `a`). Read here, before dispatch_call
    # runs bind_args, so a tail call overwriting that register during
    # arg-binding still sees the right callee.
    private def exec_call_local(frame : CallFrame, instr : Instruction, tail : Bool) : SchemeValue?
      dispatch_call(frame, instr, @stack.unsafe_fetch(frame.base + instr.d), tail)
    end

    # Op::CallUpval / Op::TailCallUpval — the callee is a closed-over
    # variable, at upvalue index `d`.
    private def exec_call_upval(frame : CallFrame, instr : Instruction, tail : Bool) : SchemeValue?
      dispatch_call(frame, instr, upvalue(frame, instr.d).get, tail)
    end

    # Returns a non-nil value only when this call unwound the VM's OUTERMOST
    # frame (a tail call from the top-level program chunk itself) — the
    # caller (`execute`'s main loop) must return it immediately. `callee` is
    # resolved by the caller (from register `a`, the global cache, a local
    # register, or an upvalue — see the exec_call* wrappers above); `a` is
    # always just the contiguous-arg anchor (args at a+1..a+b) regardless.
    private def dispatch_call(frame : CallFrame, instr : Instruction, callee : SchemeValue, tail : Bool) : SchemeValue?
      caller_base = frame.base
      nargs = instr.b
      arg_base = caller_base + instr.a + 1
      # frame.ip was already advanced past THIS instruction at the top of
      # execute's loop, so index back one to find its recorded call-site
      # position (see compile_app — Op::Call/TailCall are the only ops that
      # currently thread a real one through; most instructions have nil
      # here, which just leaves current_pos at whatever it was last set to).
      # Bounds-check-free: `frame.ip - 1` is always a valid index into this
      # same chunk's own `positions` — Chunk#emit keeps it 1:1-sized with
      # `instructions` (a slot appended for every instruction, exactly the
      # same invariant global_cache_values/global_cache_versions already
      # rely on elsewhere in this file) — so unlike most other call sites in
      # this VM, this one WAS still paying an ordinary bounds-checked
      # Array#[]? on every single call/tail-call until now.
      pos = frame.chunk.positions.unsafe_fetch(frame.ip - 1)
      @interp.current_pos = pos if pos
      callee = callee.select_clause(nargs) if callee.is_a?(BytecodeCaseClosure)
      if callee.is_a?(BytecodeClosure)
        # Tail calls reuse the current frame (@depth doesn't grow for a tail
        # loop) — only a non-tail push can run away, so only THIS path
        # needs the check. Without it, unbounded non-tail recursion just
        # grows @stack/@frames forever instead of raising a clean,
        # sandboxable error, exactly what max_eval_depth exists to prevent.
        if !tail && @depth >= @interp.max_eval_depth
          raise SchemeExecutionLimitError.new("recursion depth exceeded")
        end
        new_base = tail ? caller_base : caller_base + frame.chunk.num_registers
        ensure_stack_size(new_base + callee.chunk.num_registers)
        # Reading args out of @stack BEFORE writing params back into
        # (possibly, for a tail call) the very same stack region is safe
        # without an intermediate copy: the compiler always allocates a
        # call's callee+args registers strictly ABOVE any of the current
        # function's own live locals, so arg_base is always > any
        # destination param index a tail call could overwrite here.
        close_upvalues(frame) if tail
        bind_args(callee.chunk, nargs, new_base, @stack) { |i| @stack.unsafe_fetch(arg_base + i) }
        if tail
          # Collapse into the SAME interpreter frame if one's already
          # installed for this activation (the common case, so a tail loop
          # shows one backtrace frame, not one per iteration); the two exceptions
          # with nothing yet to overwrite are VM#run's still-nameless
          # outermost activation, and VM#call's outermost activation (whose
          # frame belongs to Interpreter#apply, not us — pushing our OWN
          # here instead of overwriting keeps that ownership distinction
          # intact, see CallFrame#owns_interp_frame).
          if frame.has_interp_frame
            @interp.set_top_frame(callee.chunk.name, pos)
          else
            @interp.push_frame(callee.chunk.name, pos)
            frame.owns_interp_frame = true
          end
          frame.reset(callee.chunk, new_base, callee, frame.return_reg, callee.root_env)
          frame.has_interp_frame = true
        else
          @interp.push_frame(callee.chunk.name, pos)
          push_frame(callee.chunk, new_base, callee, instr.c, callee.root_env)
          top_frame.has_interp_frame = true
          top_frame.owns_interp_frame = true
        end
        nil
      else
        # Shape-guarded fast path for record accessors/mutators (see
        # RecordAccessor/RecordMutator in record.cr): the accessor value
        # carries its target record_type + field_index statically, so a
        # matching-type call is just a type guard + a direct field load/store
        # — skipping the per-call args-array allocation and the generic apply
        # path (arity check, etc.) that every other builtin pays. An arity or
        # type mismatch falls through to the generic path below, which raises
        # with the accessor's own fn (identical message/semantics).
        if callee.is_a?(RecordAccessor) && nargs == 1
          rec = @stack.unsafe_fetch(arg_base)
          if rec.is_a?(SchemeRecord) && rec.type.same?(callee.record_type)
            val = rec.fields.unsafe_fetch(callee.field_index)
            return tail ? deliver_return(val) : (@stack.unsafe_put(caller_base + instr.c, val); nil)
          end
        elsif callee.is_a?(RecordMutator) && nargs == 2
          rec = @stack.unsafe_fetch(arg_base)
          if rec.is_a?(SchemeRecord) && rec.type.same?(callee.record_type)
            rec.fields[callee.field_index] = @stack.unsafe_fetch(arg_base + 1)
            return tail ? deliver_return(NIL) : (@stack.unsafe_put(caller_base + instr.c, NIL); nil)
          end
        end
        args = Array(SchemeValue).new(nargs) { |i| @stack.unsafe_fetch(arg_base + i) }
        val = @interp.apply(callee, args, pos)
        if tail
          deliver_return(val)
        else
          @stack.unsafe_put(caller_base + instr.c, val)
          nil
        end
      end
    end
  end
end
