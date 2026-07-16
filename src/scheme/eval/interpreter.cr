# ===========================================================================
# Interpreter: setup, apply, and the shared helpers the analyzer/VM use
# ===========================================================================
# The evaluator itself is the BytecodeCompiler/VM pair (over the analyzer's
# Node AST); this file holds construction, `apply` (the single bridge every
# callable value goes through), and the parsing/binding helpers
# (parse_formals, bind_params, macro/cond-expand support) shared across the
# pipeline.

module Scheme
  class Interpreter
    include Scheme::BuiltinHelpers

    DEFAULT_MAX_EVAL_DEPTH = 5_000

    getter global : Env
    # Where builtins/prelude/bytevectors/exceptions/special-forms physically
    # live — the source every (scheme base)/(scheme write)/sub-library/
    # (list ...) installer copies its bindings from via `@base_env.get(name)`.
    # Distinct from @global (the top-level program's own root Env) so that
    # auto_import_base: false can leave @global empty until the program
    # explicitly (import (scheme base)), without needing a second copy of
    # every builtin.
    getter base_env : Env
    # Directory stack for resolving a relative `load`/`include` path against
    # the loading file's own directory rather than the process's CWD — see
    # import.cr and modules/scheme/load.cr.
    getter load_dirs : Array(String)
    # (creme random)'s shared RNG — an Interpreter-instance ivar (not a
    # module/class-level variable) so reseeding via random-seed! never
    # leaks state across separate Interpreter instances.
    property random_rng : Random = Random.new
    # A fixed reference point captured at construction, for (scheme time)'s
    # current-jiffy — an arbitrary monotonic counter, per R7RS, not tied to
    # any particular epoch.
    getter start_instant : Time::Instant
    # Stack of installed with-exception-handler handler procedures — see
    # modules/scheme/base/exceptions.cr for raise/raise-continuable/
    # with-exception-handler's push/pop-while-invoking protocol.
    getter exception_handlers : Array(SchemeValue)
    property max_eval_depth : Int32
    property max_steps : Int32?

    # Restricts which libraries (import ...) may resolve, by space-joined
    # name (e.g. "creme sql" for (creme sql), "scheme base" for (scheme
    # base)) — nil (the default) means unrestricted. Renamed from the
    # require-era allowed_modules (a bare module-name allowlist) now that
    # import/library names are the unit of access control.
    property allowed_libraries : Array(String)?

    # Directories searched (in order) for a "#{a}/#{b}/#{c}.sld" file when
    # (import (a b c)) names something other than a Crystal-native library —
    # e.g. modules/creme/sxql.sld. Empty by default: a host embedding this
    # library opts in explicitly (see main.cr/spec_helper.cr), rather than
    # the interpreter silently depending on a filesystem layout. This list
    # IS the access-control boundary for file-based libraries (there's no
    # raw-path import form the way require had (require "some/path.scm"),
    # so there's no separate library_load_paths-style path-escape gate to
    # rename from require-era module_load_paths — only files discoverable
    # under these directories, via a name whose segments are validated
    # against path traversal in SchemeLibrary.parse_library_name, are ever
    # reachable).
    property library_search_path : Array(String)

    # Real R7RS parameter objects backing current-output-port/
    # current-input-port/current-error-port, so `(parameterize
    # ((current-output-port p)) ...)` genuinely redirects display/write/
    # newline's no-port-given default target — the portable mechanism
    # (scheme eval)'s eval + this needs to replace eval-string's old
    # Crystal-side @stdout swap (see modules/scheme/base.cr's emit).
    # Each parameter's default (unparameterized) value is a SchemePort
    # wrapping @stdout/@stdin/@stderr directly — the stdout=/stdin=/
    # stderr= setters below resync that same port's `.io` whenever set,
    # so they keep working exactly as before when no script has
    # parameterized the port itself.
    getter current_output_port : SchemeParameter
    getter current_input_port : SchemeParameter
    getter current_error_port : SchemeParameter

    def stdout : IO
      @stdout
    end

    def stdout=(io : IO) : IO
      @stdout = io
      default_output_port.io = io
      io
    end

    def stdin : IO
      @stdin
    end

    def stdin=(io : IO) : IO
      @stdin = io
      default_input_port.io = io
      io
    end

    def stderr : IO
      @stderr
    end

    def stderr=(io : IO) : IO
      @stderr = io
      default_error_port.io = io
      io
    end

    # The SchemePort each current_*_port parameter is constructed with at
    # startup (before any parameterize) — stdout=/stdin=/stderr= resync
    # THIS object's `.io` in place, rather than replacing the parameter's
    # value outright, so a currently-active `parameterize` isn't clobbered
    # by an unrelated `interp.stdout = io` call racing with it.
    private def default_output_port : SchemePort
      current_output_port.value.as(SchemePort)
    end

    private def default_input_port : SchemePort
      current_input_port.value.as(SchemePort)
    end

    private def default_error_port : SchemePort
      current_error_port.value.as(SchemePort)
    end

    def initialize(
      @max_eval_depth : Int32 = DEFAULT_MAX_EVAL_DEPTH,
      @max_steps : Int32? = nil,
      @allowed_libraries : Array(String)? = nil,
      @library_search_path : Array(String) = [] of String,
      @stdout : IO = STDOUT,
      @stdin : IO = STDIN,
      @stderr : IO = STDERR,
      auto_import_base : Bool = true,
    )
      @base_env = Env.new
      @global = Env.new
      @load_dirs = [] of String
      @libraries = {} of Array(String) => SchemeLibrary
      @libraries_loading = Set(Array(String)).new
      @eval_depth = 0
      @step_count = 0
      @gensym_counter = 0
      @cc_tag_counter = 0_i64
      @live_continuation_tags = Set(Int64).new
      @call_stack = [] of Frame
      @current_pos = nil.as(SourcePos?)
      @sample_interval = nil.as(Int32?)
      @sample_countdown = 0
      @sample_counts = {} of SampleKey => Int32
      @start_instant = Time.instant
      @exception_handlers = [] of SchemeValue
      # Compile-time macro scope for the analyzer's analyze-time expansion (see
      # analyzer.cr). Root scope persists; bodies push children.
      @analyzing_macros = MacroEnv.new
      @macro_expand_depth = 0
      @current_output_port = SchemeParameter.new(SchemePort.new(@stdout, false, true))
      @current_input_port = SchemeParameter.new(SchemePort.new(@stdin, true, false))
      @current_error_port = SchemeParameter.new(SchemePort.new(@stderr, false, true))
      install_builtins(@base_env)
      install_bytevectors(@base_env)
      install_exceptions(@base_env)
      install_special_forms(@base_env)
      load_prelude
      install_base_and_write_libraries
      install_all_libraries
      # Special forms (if/define/import/...) must always be visible so a
      # program can even parse far enough to reach its own `import`
      # statement — these are syntactic keywords, not (scheme base)
      # content, so they're copied into @global unconditionally regardless
      # of auto_import_base.
      SPECIAL_FORM_NAMES.each { |name| @global.define(name, @base_env.get(name)) }
      if auto_import_base
        AUTO_IMPORTED_LIBRARIES.each do |name|
          library = @libraries[name]
          SchemeLibrary.import_bindings(@global, library.exports.map { |external, internal| {external, library, internal} })
        end
      end
    end

    # Every syntactic keyword the analyzer recognizes — bound in @global as a
    # SchemeSpecialForm marker so each one participates in ordinary lexical
    # scoping/import/export/rename like any other identifier (see
    # SchemeSpecialForm's doc comment in values.cr). Keep in sync with
    # SPECIAL_FORM_KEYWORDS and the analyze_special_form dispatch.
    SPECIAL_FORM_NAMES = %w[
      quote quasiquote unquote unquote-splicing
      if cond case when unless cond-expand
      define defmacro define-record-type define-syntax define-library import
      define-values let-values let*-values let-syntax letrec-syntax
      set! lambda λ case-lambda delay parameterize guard
      let let* letrec letrec* do begin and or
      include include-ci
    ]

    def install_special_forms(env : Env) : Nil
      SPECIAL_FORM_NAMES.each { |name| env.define(name, SchemeSpecialForm.new(name)) }
    end

    # Safe-by-default entry point for embedding untrusted/semi-trusted guest
    # code: denies all library imports and captures stdout/stdin unless told
    # otherwise, so a host can't accidentally embed a wide-open interpreter
    # by forgetting to pass allowed_libraries: — and guest code reading
    # (read-line) can't block on the host's real terminal input.
    # auto_import_base defaults to false here (unlike Interpreter.new) so
    # "denies all library imports" is actually true: auto-import binds
    # (scheme base)/(scheme write)/(creme extra) into @global at
    # construction, bypassing allowed_libraries entirely (see
    # AUTO_IMPORTED_LIBRARIES in modules/scheme/base.cr) — leaving it
    # true here would silently hand guest code a working base environment
    # no matter what allowed_libraries said.
    def self.sandboxed(
      allowed_libraries : Array(String) = [] of String,
      max_steps : Int32? = 100_000,
      max_eval_depth : Int32 = DEFAULT_MAX_EVAL_DEPTH,
      stdout : IO = IO::Memory.new,
      stdin : IO = IO::Memory.new,
      stderr : IO = IO::Memory.new,
      auto_import_base : Bool = false,
    ) : Interpreter
      new(max_eval_depth: max_eval_depth, max_steps: max_steps, allowed_libraries: allowed_libraries, stdout: stdout, stdin: stdin, stderr: stderr, auto_import_base: auto_import_base)
    end

    # ---- Evaluation (trampolined) --------------------------------------------

    # ---- Backtrace support ----------------------------------------------------

    @@current_stack = [] of Interpreter

    # The interpreter instance whose eval() call chain is currently active on
    # this fiber, if any — used so a SchemeError can eagerly capture a
    # backtrace at construction time without every raise site needing a
    # reference to the interpreter.
    def self.current : Interpreter?
      @@current_stack.last?
    end

    def self.push_current(interp : Interpreter) : Nil
      @@current_stack << interp
    end

    def self.pop_current : Nil
      @@current_stack.pop?
    end

    def call_stack_snapshot : Array(Frame)
      @call_stack.dup
    end

    def current_pos : SourcePos?
      @current_pos
    end

    def current_pos=(pos : SourcePos?) : SourcePos?
      @current_pos = pos
    end

    # The register VM's own equivalent of eval_node's Frame push/pop around
    # each call (see eval/vm.cr's exec_call/deliver_return) — exposed
    # publicly since the VM is a separate class from Interpreter, unlike
    # the tree-walker's own apply/eval_node which push/pop @call_stack
    # directly as instance methods of this same class.
    def push_frame(name : String, pos : SourcePos?) : Nil
      @call_stack << Frame.new(name, pos)
    end

    def pop_frame : Nil
      @call_stack.pop
    end

    # Overwrites the top frame in place — backs tail-call collapsing (a
    # self-tail-recursive loop of N iterations shows up as ONE frame, not
    # N), matching eval_node_core's own `@call_stack[-1] = Frame.new(...)`
    # for a tail call.
    def set_top_frame(name : String, pos : SourcePos?) : Nil
      @call_stack[-1] = Frame.new(name, pos) unless @call_stack.empty?
    end

    # ---- Scheme-level cooperative sampling profiler ----------------------------
    #
    # prof.cr's SIGPROF sampler only ever sees Crystal frames (VM#execute,
    # #apply, ...) since every Scheme call funnels through the same handful of
    # Crystal methods — it can't tell a Scheme function call from an `if` from
    # a `cons`. This is a second, independent sampler that instead periodically
    # inspects whichever bytecode instruction the VM's own dispatch loop
    # (VM#execute, eval/vm.cr) is about to run — driven from a plain counter
    # checked once per dispatched instruction (VM#execute calls
    # Interpreter#tick_sample), not a signal handler, so it's free of the
    # signal-safety concerns a SIGPROF handler would have reading interpreter
    # state mid-mutation.
    #
    # Samples are attributed to the CURRENT INSTRUCTION about to execute, not
    # to the innermost enclosing named call — attributing to the enclosing
    # call alone collapses to a single entry (e.g. profiling `(fib 27)` would
    # show 100% "fib" with no visibility into `if`/`-`/`+`/the recursive call
    # itself), since a builtin call like `cons` completes entirely within one
    # instruction dispatch, so a sample checkpoint could never land "inside"
    # it — only a Lambda call (whose body spans many instructions) would ever
    # be observable that way. Sampling the current instruction directly
    # sidesteps that. Most instructions carry no special meaning of their own
    # (a bare Move/LoadK/GetGlobal), so BytecodeCompiler additionally tags a
    # handful of instruction indices with richer metadata at compile time —
    # a call site's reconstructed source text ("(fib (- n 1))"), a fused
    # primitive's own Scheme name ("+"), or a control construct's keyword
    # ("if"/"when"/"cond"/"case") — via Chunk#tag_sample/#sample_tags;
    # everything else falls back to a plain per-Op label (#op_label).
    #
    # The countdown between samples is JITTERED (uniform in 1..2*interval,
    # mean == interval), not fixed — a recursive function's body dispatches
    # the same sequence of instructions in the same order on every call, so a
    # fixed step interval can alias with that period and always land on the
    # same phase (confirmed on the tree-walker's equivalent sampler: a fixed
    # interval of 50 reported 100% of samples on the one node type that
    # happened to line up with the stride, while an interval of 1, or a
    # jittered interval, both reproduce the expected proportional breakdown).
    # This is the same aliasing hazard any fixed-rate sampler faces against a
    # periodic signal; jittering the phase is the standard fix.

    # A sample key: a {name, instruction, file, line} tuple — file/line
    # nilable since not every instruction resolves a source position (see
    # Chunk#positions).
    alias SampleKey = {String, String, String?, Int32?}

    def start_scheme_sampling(interval_steps : Int32) : Nil
      @sample_interval = interval_steps
      @sample_countdown = jittered_sample_countdown(interval_steps)
      @sample_counts = {} of SampleKey => Int32
    end

    def stop_scheme_sampling : Hash(SampleKey, Int32)
      counts = @sample_counts
      @sample_interval = nil
      counts
    end

    private def jittered_sample_countdown(interval_steps : Int32) : Int32
      Random.rand(1..(2 * interval_steps))
    end

    # Called by VM#execute once per dispatched instruction — a no-op unless
    # sampling is active (checked by the caller via #sample_interval so an
    # ordinary, non-profiled run never even reaches this method).
    def tick_sample(interval : Int32, chunk : Chunk, ip : Int32) : Nil
      @sample_countdown -= 1
      return if @sample_countdown > 0
      @sample_countdown = jittered_sample_countdown(interval)
      record_sample(chunk, ip)
    end

    def sample_interval : Int32?
      @sample_interval
    end

    # Called by VM#execute_limited/#execute_sampled_limited once per
    # dispatched instruction — a no-op unless max_steps is actually set
    # (checked by the caller via #max_steps so an unbounded run never even
    # reaches this method). @step_count itself is reset once per independent
    # top-level form by BytecodeCompiler.run_program, not here — an earlier
    # form's cost must never eat into a later one's budget, but a single
    # form's own nested calls (map/for-each/apply callbacks, ...) all share
    # the same running total, exactly like max_eval_depth's @depth.
    def tick_step_limit(limit : Int32) : Nil
      @step_count += 1
      raise SchemeExecutionLimitError.new("execution step limit exceeded") if @step_count > limit
    end

    # Called by BytecodeCompiler.run_program before compiling/running each
    # independent top-level form — see tick_step_limit's own doc comment.
    def reset_step_count : Nil
      @step_count = 0
    end

    private def record_sample(chunk : Chunk, ip : Int32) : Nil
      key = sample_key(chunk, ip)
      @sample_counts[key] = (@sample_counts[key]? || 0) + 1
    end

    private def sample_key(chunk : Chunk, ip : Int32) : SampleKey
      pos = chunk.positions[ip]?
      name, instruction = if tag = chunk.sample_tags[ip]?
                            {tag[1], tag[0]}
                          else
                            label = Interpreter.op_label(chunk.instructions[ip].op)
                            {label, label}
                          end
      {name, instruction, pos.try(&.file), pos.try(&.line)}
    end

    # The KIND of thing an untagged instruction does, in the language's own
    # syntax where one exists (e.g. "+"/"call"/"local-ref") rather than a raw
    # Crystal enum member name — used as both the name and instruction
    # columns for any instruction BytecodeCompiler didn't tag more
    # specifically (see Chunk#sample_tags).
    # ameba:disable Metrics/CyclomaticComplexity
    def self.op_label(op : Op) : String
      case op
      when Op::Add    then "+"
      when Op::Sub    then "-"
      when Op::Mul    then "*"
      when Op::NumLt  then "<"
      when Op::NumLe  then "<="
      when Op::NumGt  then ">"
      when Op::NumGe  then ">="
      when Op::NumEq  then "="
      when Op::VecRef then "vector-ref"
      when Op::VecSet then "vector-set!"
      when Op::VecLen then "vector-length"
      when Op::StrRef then "string-ref"
      when Op::StrSet then "string-set!"
      when Op::BvRef  then "bytevector-u8-ref"
      when Op::BvSet  then "bytevector-u8-set!"
      when Op::Cons   then "cons"
      when Op::Not    then "not"
      when Op::IsNull then "null?"
      when Op::IsPair then "pair?"
      when Op::Call, Op::TailCall
        "call"
      when Op::Closure, Op::MakeCaseClosure
        "lambda"
      when Op::DefGlobal then "define"
      when Op::SetGlobal, Op::SetUpval
        "set!"
      when Op::Move      then "local-ref"
      when Op::GetGlobal then "global-ref"
      when Op::GetUpval  then "upval-ref"
      when Op::LoadK, Op::LoadNil, Op::LoadTrue, Op::LoadFalse
        "literal"
      when Op::Return then "return"
      else
        op.to_s.downcase
      end
    end

    # ---- Application ----------------------------------------------------------

    def apply(callee : SchemeValue, args : Array(SchemeValue), pos : SourcePos? = nil) : SchemeValue
      case callee
      when Builtin
        check_arity(callee, args)
        @call_stack << Frame.new(callee.name, pos)
        begin
          callee.fn.call(args)
        ensure
          @call_stack.pop
        end
      when BytecodeClosure
        # Bridges a builtin (map, for-each, sort, apply, ...) calling back
        # into a register-VM closure — runs it to completion in a fresh
        # frame stack and returns its result. See eval/vm.cr#call. Pushes a
        # Frame exactly like the Lambda arm above, so this call shows up
        # in a backtrace the same way regardless of which evaluator built
        # the closure; VM#call marks its own outermost activation as
        # already covered by this frame (see CallFrame#has_interp_frame),
        # so a later self-tail-call from THIS closure correctly overwrites
        # it instead of leaving it doubled up.
        @call_stack << Frame.new(callee.chunk.name, pos)
        begin
          VM.new(self, callee.root_env).call(callee, args)
        ensure
          @call_stack.pop
        end
      when BytecodeCaseClosure
        clause = callee.select_clause(args.size)
        @call_stack << Frame.new(clause.chunk.name, pos)
        begin
          VM.new(self, clause.root_env).call(clause, args)
        ensure
          @call_stack.pop
        end
      when Macro
        raise SchemeRuntimeError.new("macro cannot be applied as a procedure: #{callee.name}")
      when SchemeParameter
        raise SchemeRuntimeError.new("parameter: expected 0 arguments, got #{args.size}") unless args.empty?
        callee.value
      when SchemeContinuation
        raise SchemeRuntimeError.new("continuation: expected 1 argument, got #{args.size}") unless args.size == 1
        unless @live_continuation_tags.includes?(callee.tag)
          raise SchemeRuntimeError.new("continuation invoked outside its dynamic extent")
        end
        raise ContinuationInvoked.new(callee.tag, args[0])
      else
        raise SchemeRuntimeError.new("not applicable: #{callee.write_string}")
      end
    end

    private def check_arity(b : Builtin, args : Array(SchemeValue)) : Nil
      n = args.size
      if n < b.min_arity
        raise SchemeRuntimeError.new("#{b.name}: expected at least #{b.min_arity} argument(s), got #{n}")
      end
      if b.max_arity >= 0 && n > b.max_arity
        raise SchemeRuntimeError.new("#{b.name}: expected at most #{b.max_arity} argument(s), got #{n}")
      end
    end

    private def bind_params(lam : Macro, args : Array(SchemeValue), call_env : Env) : Nil
      params = lam.params
      rest = lam.rest
      if rest
        if args.size < params.size
          raise SchemeRuntimeError.new("#{lam.name}: expected at least #{params.size} argument(s), got #{args.size}")
        end
      else
        if args.size != params.size
          raise SchemeRuntimeError.new("#{lam.name}: expected #{params.size} argument(s), got #{args.size}")
        end
      end
      params.each_with_index do |param, i|
        call_env.define(param, args[i])
      end
      if r = rest
        extra = args[params.size..-1]
        call_env.define(r, Scheme.a_to_list(extra))
      end
    end

    # ---- Special-form helpers -------------------------------------------------

    def eval_defmacro(expr : Cons, env : Env) : SchemeValue
      name, mac = build_macro(expr, env)
      env.define(name, mac)
      SchemeSym.of(name)
    end

    # Expand a defmacro call: bind the unevaluated arg forms to the macro's
    # params and run its body (analyze + eval_node each form), returning the
    # expansion.
    def expand_defmacro(macro_def : Macro, form : Cons) : SchemeValue
      arg_forms = [] of SchemeValue
      c = form.cdr
      while c.is_a?(Cons)
        arg_forms << c.car
        c = c.cdr
      end
      raise SchemeRuntimeError.new("cannot apply: improper argument list") unless c.is_a?(SchemeNil)
      call_env = Env.new(macro_def.env)
      bind_params(macro_def, arg_forms, call_env)
      # The body is arbitrary code run at expansion time; compile+run each form.
      BytecodeCompiler.run_program(self, macro_def.body, call_env)
    end

    # Parse (defmacro name formals body...) into {name, Macro} (capturing `env`)
    # without registering — used by eval_defmacro and analyze-time expansion.
    def build_macro(expr : Cons, env : Env) : {String, Macro}
      rest = expr.cdr
      raise SchemeRuntimeError.new("defmacro: malformed") unless rest.is_a?(Cons)
      name = rest.car
      raise SchemeRuntimeError.new("defmacro: macro name must be a symbol") unless name.is_a?(SchemeSym)
      formals_rest = rest.cdr
      raise SchemeRuntimeError.new("defmacro: malformed") unless formals_rest.is_a?(Cons)
      formals = formals_rest.car
      body = Scheme.list_to_a(formals_rest.cdr)
      raise SchemeRuntimeError.new("defmacro: macro body is empty") if body.empty?
      params, rparam = parse_formals(formals)
      {name.name, Macro.new(params, rparam, body, env, name.name)}
    end

    # Picks the first clause whose arity accepts `argc` — an exact match for
    # a fixed-arity clause (no rest param), or argc >= params.size for a
    # clause with one. Shared by apply's non-tail CaseLambda arm and
    # eval_node's AppNode tail-call arm, so both dispatch identically.
    # Returns {params, rest}
    def parse_formals(spec : SchemeValue) : {Array(String), String?}
      params = [] of String
      rest : String? = nil
      case spec
      when SchemeSym
        # (lambda args ...) full variadic
        rest = spec.name
      when SchemeNil
        # no params
      when Cons
        cur : SchemeValue = spec
        while cur.is_a?(Cons)
          head = cur.car
          raise SchemeRuntimeError.new("bad formal parameter: #{head.write_string}") unless head.is_a?(SchemeSym)
          params << head.name
          cur = cur.cdr
        end
        unless cur.is_a?(SchemeNil)
          raise SchemeRuntimeError.new("bad rest parameter: #{cur.write_string}") unless cur.is_a?(SchemeSym)
          rest = cur.name
        end
      else
        raise SchemeRuntimeError.new("bad formals: #{spec.write_string}")
      end
      {params, rest}
    end

    private def bind_values(who : String, params : Array(String), rparam : String?, vals : Array(SchemeValue), env : Env) : Nil
      if rparam
        raise SchemeRuntimeError.new("#{who}: expected at least #{params.size} value(s), got #{vals.size}") if vals.size < params.size
      else
        raise SchemeRuntimeError.new("#{who}: expected #{params.size} value(s), got #{vals.size}") if vals.size != params.size
      end
      params.each_with_index { |name, i| env.define(name, vals[i]) }
      env.define(rparam, Scheme.a_to_list(vals[params.size..])) if rparam
    end

    private def cond_expand_matches?(requirement : SchemeValue) : Bool
      case requirement
      when SchemeSym
        features.includes?(requirement.name)
      when Cons
        head = requirement.car
        raise SchemeRuntimeError.new("cond-expand: bad requirement") unless head.is_a?(SchemeSym)
        args = Scheme.list_to_a(requirement.cdr)
        case head.name
        when "and" then args.all? { |arg| cond_expand_matches?(arg) }
        when "or"  then args.any? { |arg| cond_expand_matches?(arg) }
        when "not"
          raise SchemeRuntimeError.new("cond-expand: not expects 1 argument") unless args.size == 1
          !cond_expand_matches?(args[0])
        when "library"
          raise SchemeRuntimeError.new("cond-expand: library expects 1 argument") unless args.size == 1
          @libraries.has_key?(SchemeLibrary.parse_library_name(args[0]))
        else
          raise SchemeRuntimeError.new("cond-expand: unknown requirement '#{head.name}'")
        end
      else
        raise SchemeRuntimeError.new("cond-expand: bad requirement #{requirement.write_string}")
      end
    end

    # Feature identifiers this interpreter satisfies for cond-expand's
    # feature-identifier requirement form (distinct from the `features`
    # base-library procedure, which returns this same list as a Scheme
    # value — see modules/scheme/base.cr).
    def features : Array(String)
      %w[r7rs creme creme.cr]
    end

    # ---- Quasiquote -----------------------------------------------------------
  end
end
