# ===========================================================================
# Interpreter: setup, apply, and the shared helpers the analyzer/VM use
# ===========================================================================
# The evaluator itself is the BytecodeCompiler/VM pair (over the analyzer's
# Node AST); this file holds construction, `apply` (the single bridge every
# callable value goes through), and the parsing/binding helpers
# (parse_formals, bind_params, macro/cond-expand support) shared across the
# pipeline.

module Creme
  class Interpreter
    include Creme::BuiltinHelpers

    DEFAULT_MAX_EVAL_DEPTH = 5_000

    # Warm baseline of pooled VM instances kept per Interpreter (see
    # @vm_pool / ObjectPool). Small: covers the common non-nested apply
    # callback depth without pre-allocating much; the pool grows past it
    # under deeper nesting and declines back toward it when idle.
    VM_POOL_MIN = 4

    # Warm baseline of pooled child Interpreters kept per ROOT Interpreter
    # (see #interp_pool) — e.g. one per concurrently in-flight HTTP request
    # under (creme mux). Same rationale as VM_POOL_MIN: small, grows under
    # load, declines when idle.
    INTERP_POOL_MIN = 4

    getter global : Env
    # Lazily built on first apply (see #vm_pool) rather than in initialize:
    # the factory block captures `self`, which Crystal's in-initialize ivar
    # analysis rejects. nil until first use.
    @vm_pool : ObjectPool(VM)? = nil
    # Lazily built on first #acquire_child_interpreter, same reason as
    # @vm_pool above. nil until first use.
    @interp_pool : ObjectPool(Interpreter)? = nil
    # Guards @interp_pool. Unlike @vm_pool (which lives on a CHILD
    # Interpreter only ever touched by the one Fiber that owns it for the
    # length of one request), @interp_pool lives on the ROOT Interpreter and
    # is acquired/released by every concurrently-handled request's own
    # Fiber — exactly the kind of shared mutable state that made
    # per-request Interpreter isolation necessary in the first place (see
    # initialize(inherit_from:)'s own doc comment, and (creme mux)'s
    # request_interpreter). ObjectPool's acquire/release are bare
    # Array#pop/#push, safe only when strictly one Fiber touches the
    # structure at an instant; under -Dpreview_mt with more than one OS
    # thread, two request Fibers can call acquire/release on the SAME root
    # Interpreter's pool at literally the same time, so this needs a real
    # Mutex — cheap next to the Interpreter+4-VM+register-array allocation
    # it's saving.
    @interp_pool_mutex = Mutex.new
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
    # base)) — nil (the default) means unrestricted. Library names are the
    # unit of access control.
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

    # Set (and reset to nil right after) only by CVMEmitter.emit
    # (cvm_emitter.cr), around its own per-library second analyze pass over
    # a library's body forms — maps that ONE library's own internal
    # (non-exported) top-level names to a qualified form, so cvm's flat,
    # name-interned global table (no per-library namespacing at all — see
    # cvm/vm.c's cvm_global_intern) can't have two libraries' same-named
    # private helpers silently clobber each other's slot. Consulted by
    # Analyzer's cvm_global_name helper. nil (the default, and the state
    # for every real interpreter session/REPL) makes analysis behave
    # exactly as it always has — this property only ever matters during
    # that one emitter-internal analyze pass.
    property cvm_rename : Hash(String, String)? = nil

    # Set (and reset to false right after) only by CVMEmitter.emit, for the
    # whole duration of a --emit-cvm compile. cond_expand_matches?'s `library`
    # case consults this to answer "(library (creme builtin X))" as false
    # whenever X is a 3-segment (creme builtin ...) FFI family name, even
    # though the NATIVE bin/creme process doing this compile always has that
    # family registered for itself -- cvm, the actual target runtime the
    # emitted chunk will execute on, never does. Without this, a library's
    # own `(cond-expand ((library (creme builtin X)) ...) (else ...))` (e.g.
    # modules/creme/raft.sld) would wrongly pick the FFI branch based on the
    # COMPILING process's own capabilities rather than the TARGET's.
    property emitting_for_cvm : Bool = false

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
      @pending_libraries = {} of Array(String) => Proc(Env, Array(String))
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
      @sample_sink = nil.as(SampleSink?)
      @start_instant = Time.instant
      @exception_handlers = [] of SchemeValue
      # Compile-time macro scope for the analyzer's analyze-time expansion (see
      # analyzer.cr). Root scope persists; bodies push children.
      @analyzing_macros = MacroEnv.new
      @macro_expand_depth = 0
      @current_output_port = SchemeParameter.new(SchemePort.new(@stdout, false, true))
      @current_input_port = SchemeParameter.new(SchemePort.new(@stdin, true, false))
      @current_error_port = SchemeParameter.new(SchemePort.new(@stderr, false, true))
      base_names = install_builtins(@base_env)
      base_names.concat(install_bytevectors(@base_env))
      base_names.concat(install_exceptions(@base_env))
      write_names = install_write(@base_env)
      install_special_forms(@base_env)
      load_prelude
      install_builtin_libraries(base_names, write_names)
      install_scheme_base_and_write_libraries
      install_all_libraries
      install_cxr_conveniences
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

    # Read-only view of the registered libraries, keyed by their dotted name
    # (e.g. ["creme", "sql"]) — needed so a spawned actor's own Interpreter
    # (see `initialize(inherit_from:)` below) can start from the same set of
    # already-loaded libraries as its parent instead of re-registering
    # everything.
    getter libraries : Hash(Array(String), SchemeLibrary)

    # Read-only view of native libraries declared (via register_library)
    # but not yet constructed — see builtin_registration.cr's
    # register_pending_library/construct_pending_library. Needed for the
    # same inherit_from reason as @libraries: a spawned actor's Interpreter
    # must start with the same "not yet built" set as its parent, so it can
    # still lazily construct a family the parent hasn't touched, without
    # re-constructing (or losing access to) one the parent already has.
    getter pending_libraries : Hash(Array(String), Proc(Env, Array(String)))

    # Lightweight constructor for a spawned actor's own Fiber (see (creme
    # actor)'s `spawn`): gets its own independent per-fiber execution state —
    # required since eval-depth/step-count/call-stack bookkeeping (and
    # Interpreter.current's Fiber-keyed stack) assumes exactly one Fiber ever
    # touches a given Interpreter instance. Skips the normal constructor's
    # install_builtins/load_prelude/install_all_libraries work entirely,
    # since @base_env/@global/@libraries are inherited rather than rebuilt.
    #
    # @base_env is shared with the parent by literal reference — safe since
    # nothing mutates it once the root Interpreter's constructor finishes
    # (every `define` into it happens during `install_builtins`/etc., before
    # any actor can exist to spawn concurrently against it), so concurrent
    # reads from multiple actor Fibers need no lock.
    #
    # @global and @libraries are NOT shared by reference — each actor gets
    # its own private overlay so its own top-level `define`/`set!`/`import`
    # can never race with a sibling actor's (or the parent's) writes into the
    # same underlying Hash. @global is a fresh child Env whose parent is the
    # spawning interpreter's own @global: `Env#get`/`get?` fall through the
    # chain, so every binding visible at spawn time (helper functions, record
    # types, ...) is still visible to the actor, but a `define` the actor
    # makes lands only in its own frame, never the shared one. @libraries is
    # a shallow `dup` of the parent's table for the same reason — the
    # loaded SchemeLibrary values themselves stay shared (a library's own Env
    # is fixed once its body has finished loading), only the "which names are
    # loaded" table needs to be a private copy so a first-time `(import ...)`
    # in one actor doesn't mutate every other actor's view of it.
    def initialize(inherit_from parent : Interpreter)
      @max_eval_depth = parent.max_eval_depth
      @max_steps = parent.max_steps
      @allowed_libraries = parent.allowed_libraries
      @library_search_path = parent.library_search_path
      @stdout = parent.stdout
      @stdin = parent.stdin
      @stderr = parent.stderr
      @base_env = parent.base_env
      @global = Env.new(parent.global)
      @libraries = parent.libraries.dup
      @pending_libraries = parent.pending_libraries.dup
      @load_dirs = parent.load_dirs.dup
      @libraries_loading = Set(Array(String)).new
      @eval_depth = 0
      @step_count = 0
      @gensym_counter = 0
      @cc_tag_counter = 0_i64
      @live_continuation_tags = Set(Int64).new
      @call_stack = [] of Frame
      @current_pos = nil.as(SourcePos?)
      # Inherits the parent's sampling config (if profile-scheme is
      # currently running on it) and shares its SampleSink by reference, so
      # samples this child's own VM instance records (e.g. one HTTP
      # request's worth of work under (creme mux) — see mux.cr's own
      # request_interpreter) are aggregated into the same report the parent
      # eventually gets back from stop_scheme_sampling — see SampleSink's
      # own doc comment for why this sharing is required at all. A parent
      # that ISN'T sampling propagates nil/0 here exactly as before.
      @sample_interval = parent.sample_interval
      @sample_countdown = (interval = @sample_interval) ? jittered_sample_countdown(interval) : 0
      @sample_sink = parent.sample_sink
      @start_instant = Time.instant
      @exception_handlers = [] of SchemeValue
      @analyzing_macros = MacroEnv.new
      @macro_expand_depth = 0
      @current_output_port = SchemeParameter.new(SchemePort.new(@stdout, false, true))
      @current_input_port = SchemeParameter.new(SchemePort.new(@stdin, true, false))
      @current_error_port = SchemeParameter.new(SchemePort.new(@stderr, false, true))
    end

    # Pool of reusable VM instances for apply's callback bridge (map/for-each/
    # handler dispatch/...), which otherwise allocated a fresh VM + 256-slot
    # register array per call. Built on first use (VM_POOL_MIN warm, grows
    # under load, declines slowly when idle — see ObjectPool).
    def vm_pool : ObjectPool(VM)
      @vm_pool ||= ObjectPool(VM).new(VM_POOL_MIN, ->(vm : VM) { vm.reset_for_reuse }) { VM.new(self, nil) }
    end

    # Returns THIS (previously in-use, now-released) child Interpreter to a
    # clean per-request starting state — the same per-request-mutable
    # fields initialize(inherit_from:) sets up for a brand-new child, but
    # reapplied with as little fresh allocation as actually matters:
    #
    # - @call_stack/@exception_handlers/@live_continuation_tags/
    #   @libraries_loading are `clear`ed in place rather than replaced with
    #   a brand-new empty Array/Set. They should already be empty by
    #   release time (every push is balanced by a pop, even on an abnormal
    #   unwind — see apply's `ensure` blocks), so this is normally a no-op
    #   scan; the win is reusing already-grown backing storage instead of
    #   discarding it and reallocating from scratch next time a deep call
    #   stack grows it back out.
    # - @libraries is merged into in place (`clear` + `merge!`) instead of
    #   `.dup`-ing a brand-new Hash every reset, for the same reason.
    # - @current_output_port/@current_input_port/@current_error_port are
    #   left untouched: `parameterize` is dynamic-wind-scoped and restores
    #   each parameter's `.value` to its default on every exit path
    #   (including a non-local one, via the VM's own unwind-action stack),
    #   so by the time a request's top-level handler call returns, these
    #   are already back to wrapping @stdout/@stdin/@stderr — recreating
    #   them would just be 6 wasted allocations for identical state.
    # - @start_instant is NOT refreshed — current-jiffy only needs to be
    #   /a/ monotonic counter from an arbitrary reference point per R7RS,
    #   not one reset per request, so there's nothing to gain by touching
    #   it here.
    # - @global and @analyzing_macros ARE still reallocated fresh (not
    #   cleared in place), and deliberately so: a closure created during
    #   this Interpreter's PREVIOUS request (e.g. one stashed into a
    #   shared (creme hash-table) or actor mailbox that outlives the
    #   request) keeps `@global` as its lexical root_env by reference: if
    #   this method cleared that same Env object's bindings in place
    #   instead of swapping in a new one, a still-live closure from a
    #   prior request would see its captured scope corrupted by whatever
    #   the NEXT request's top-level code defines. A fresh Env.new(parent)
    #   already costs just the Env object itself (no array allocation —
    #   see Env's own "empty-frame sentinel storage" doc comment), so
    #   there's no real allocation to save by trying to reuse it in place.
    #   @analyzing_macros is the same shape of hazard (a compile-time
    #   macro scope some captured-but-unevaluated form could still
    #   reference) and is a comparably tiny allocation, so it gets the
    #   same treatment.
    #
    # Deliberately does NOT touch @vm_pool: every VM #apply hands out from
    # it is already reset before being returned (see VM#reset_for_reuse),
    # so the pool itself is safe to leave warm across reuse — keeping it
    # warm is the entire reason to pool child Interpreters at all rather
    # than just reallocating them per request (see #interp_pool).
    def reset_for_reuse(parent : Interpreter) : Nil
      @global = Env.new(parent.global)
      @libraries.clear
      @libraries.merge!(parent.libraries)
      @pending_libraries.clear
      @pending_libraries.merge!(parent.pending_libraries)
      @libraries_loading.clear
      @load_dirs.clear
      @load_dirs.concat(parent.load_dirs)
      @eval_depth = 0
      @step_count = 0
      @gensym_counter = 0
      @cc_tag_counter = 0_i64
      @live_continuation_tags.clear
      @call_stack.clear
      @current_pos = nil.as(SourcePos?)
      @sample_interval = parent.sample_interval
      @sample_countdown = (interval = @sample_interval) ? jittered_sample_countdown(interval) : 0
      @sample_sink = parent.sample_sink
      @exception_handlers.clear
      @analyzing_macros = MacroEnv.new
      @macro_expand_depth = 0
    end

    # Pool of reusable CHILD Interpreters (mirrors #vm_pool one level up).
    # Reusing the whole child Interpreter instance, not just rebuilding its
    # per-request state, means its own @vm_pool survives across
    # acquisitions instead of being rebuilt from scratch (4 VMs x 256-slot
    # register arrays) on every single request — which is exactly what a
    # fresh `Interpreter.new(inherit_from: self)` per request was paying
    # for, with zero cross-request benefit (see (creme mux)'s
    # request_interpreter, mux.cr). Built on first use (INTERP_POOL_MIN
    # warm, grows under load, declines slowly when idle — see ObjectPool).
    # Call #acquire_child_interpreter/#release_child_interpreter, not this
    # directly — those two hold @interp_pool_mutex for the whole
    # acquire/release, this accessor does not (see @interp_pool_mutex's own
    # doc comment for why the lock is needed at all).
    private def interp_pool : ObjectPool(Interpreter)
      @interp_pool ||= ObjectPool(Interpreter).new(INTERP_POOL_MIN,
        ->(child : Interpreter) { child.reset_for_reuse(self) }) { Interpreter.new(inherit_from: self) }
    end

    def acquire_child_interpreter : Interpreter
      @interp_pool_mutex.synchronize { interp_pool.acquire }
    end

    def release_child_interpreter(child : Interpreter) : Nil
      @interp_pool_mutex.synchronize { interp_pool.release(child) }
    end

    # @base_env conveniences that aren't (scheme base) exports but have always
    # been available unprefixed (REPL / auto_import_base). Kept here rather than
    # as prelude closures so they resolve to real builtins and therefore fuse
    # into Op::Cxr (the analyzer fuses a call whose head resolves to a cxr-named
    # builtin — see analyzer.cr):
    #   - caddr/cdddr/cadddr: the real (scheme cxr) builtins, copied from that
    #     library (single source of truth — not reimplemented in base).
    #   - first/second/third/rest: plain value aliases; because fusion keys on
    #     the resolved builtin's name, `(define first car)` makes `(first x)`
    #     fuse exactly like `(car x)` with no dedicated alias machinery.
    private def install_cxr_conveniences : Nil
      cxr_lib = construct_pending_library(["creme", "builtin", "cxr"]) || raise "install_cxr_conveniences: (creme builtin cxr) is missing"
      cxr_env = cxr_lib.env
      %w[caddr cdddr cadddr].each { |name| @base_env.define(name, cxr_env.get(name)) }
      {"first" => "car", "second" => "cadr", "third" => "caddr", "rest" => "cdr"}.each do |alias_name, target|
        @base_env.define(alias_name, @base_env.get(target))
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

    # The external export names of a registered library — for tests/tools
    # that want to enumerate what a library provides now that these lists are
    # derived (from each library's own annotated modules) rather than held in
    # a hand-maintained SCHEME_*_EXPORTS constant.
    def library_export_names(name : Array(String)) : Array(String)
      (@libraries[name]? || resolve_library(name)).exports.keys
    end

    # Safe-by-default entry point for embedding untrusted/semi-trusted guest
    # code: denies all library imports and captures stdout/stdin unless told
    # otherwise, so a host can't accidentally embed a wide-open interpreter
    # by forgetting to pass allowed_libraries: — and guest code reading
    # (read-line) can't block on the host's real terminal input.
    # auto_import_base defaults to false here (unlike Interpreter.new) so
    # "denies all library imports" is actually true: auto-import binds
    # (scheme base)/(scheme write) into @global at construction, bypassing
    # allowed_libraries entirely (see AUTO_IMPORTED_LIBRARIES in
    # modules/scheme/base.cr) — leaving it true here would silently hand
    # guest code a working base environment no matter what allowed_libraries
    # said.
    # library_search_path defaults to ["./modules"] (not []) even here:
    # gating which libraries a guest program may reach is allowed_libraries'
    # job alone, not library_search_path's — plenty of R7RS standard names
    # (e.g. (scheme inexact)) are thin file-based frontends bundled with the
    # interpreter itself now (see modules/scheme/*.sld), not guest-supplied
    # files, so a host that widens allowed_libraries to name one must still
    # be able to actually resolve it.
    def self.sandboxed(
      allowed_libraries : Array(String) = [] of String,
      max_steps : Int32? = 100_000,
      max_eval_depth : Int32 = DEFAULT_MAX_EVAL_DEPTH,
      library_search_path : Array(String) = ["./modules"],
      stdout : IO = IO::Memory.new,
      stdin : IO = IO::Memory.new,
      stderr : IO = IO::Memory.new,
      auto_import_base : Bool = false,
    ) : Interpreter
      new(max_eval_depth: max_eval_depth, max_steps: max_steps, allowed_libraries: allowed_libraries, library_search_path: library_search_path, stdout: stdout, stdin: stdin, stderr: stderr, auto_import_base: auto_import_base)
    end

    # ---- Evaluation (trampolined) --------------------------------------------

    # ---- Backtrace support ----------------------------------------------------

    # Keyed by Fiber so concurrent actor fibers (each running their own
    # Interpreter/VM) don't corrupt each other's push/pop history — only one
    # Fiber ever touches a given key's array, but many fibers may be pushing
    # to their own arrays at once.
    @@current_stacks = {} of Fiber => Array(Interpreter)

    # Guards @@current_stacks itself (insert/delete of a Fiber's own key, and
    # the resulting internal bucket-array resize/rehash), not each fiber's
    # private Array. Different fibers only ever touch different keys, but
    # under -Dpreview_mt with more than one OS thread, two fibers' inserts
    # into the SAME Hash can land at literally the same instant — Crystal's
    # Hash isn't safe for concurrent mutation even across distinct keys, and
    # this raced in practice (segfaults during GC under real multi-core
    # parallelism; harmless under single-OS-thread cooperative fiber
    # scheduling, where mutations never truly overlap).
    @@stacks_mutex = Mutex.new

    # The interpreter instance whose eval() call chain is currently active on
    # this fiber, if any — used so a SchemeError can eagerly capture a
    # backtrace at construction time without every raise site needing a
    # reference to the interpreter.
    def self.current : Interpreter?
      @@stacks_mutex.synchronize { @@current_stacks[Fiber.current]? }.try(&.last?)
    end

    def self.push_current(interp : Interpreter) : Nil
      @@stacks_mutex.synchronize { (@@current_stacks[Fiber.current] ||= [] of Interpreter) << interp }
    end

    def self.pop_current : Nil
      @@stacks_mutex.synchronize do
        stack = @@current_stacks[Fiber.current]?
        next unless stack
        stack.pop?
        @@current_stacks.delete(Fiber.current) if stack.empty?
      end
    end

    # Same push/pop/current pattern as @@current_stacks above, but for the
    # innermost VM instance currently executing on this fiber — VM#run/#call
    # register themselves here for their own duration. Lets call_stack_snapshot
    # below synthesize that VM's own uncaptured recursion (see
    # VM#synthesize_frames) without needing every raise site to thread a VM
    # reference through, exactly like @@current_stacks does for the
    # interpreter itself. A builtin→closure bridge call (Interpreter#apply's
    # BytecodeClosure/BytecodeCaseClosure arms) nests a new VM#call inside
    # whatever VM (if any) was already current — push/pop naturally restores
    # the outer one when the inner one returns.
    @@current_vm_stacks = {} of Fiber => Array(VM)

    def self.current_vm : VM?
      @@stacks_mutex.synchronize { @@current_vm_stacks[Fiber.current]? }.try(&.last?)
    end

    def self.push_current_vm(vm : VM) : Nil
      @@stacks_mutex.synchronize { (@@current_vm_stacks[Fiber.current] ||= [] of VM) << vm }
    end

    def self.pop_current_vm : Nil
      @@stacks_mutex.synchronize do
        stack = @@current_vm_stacks[Fiber.current]?
        next unless stack
        stack.pop?
        @@current_vm_stacks.delete(Fiber.current) if stack.empty?
      end
    end

    # @call_stack already holds every REAL Interpreter::Frame — pushed by
    # Interpreter#apply for builtin calls/builtin→closure bridges, and by
    # set_top_frame for VM#call's own outermost self-tail-recursion (see
    # CallFrame#has_interp_frame). What it does NOT hold any more is a plain
    # Scheme-to-Scheme call made from within the currently active VM (see
    # dispatch_bytecode_call's own doc comment) — append those, synthesized
    # from that VM's own pooled call frames, after the real ones.
    def call_stack_snapshot : Array(Frame)
      frames = @call_stack.dup
      if vm = Interpreter.current_vm
        frames.concat(vm.synthesize_frames)
      end
      frames
    end

    # Lets Interpreter#apply push/pop a Frame onto whichever Interpreter is
    # actually active on this fiber (see apply's own doc comment), which
    # isn't necessarily `self` from that method's own point of view.
    def push_frame(f : Frame) : Nil
      @call_stack << f
    end

    def pop_frame : Nil
      @call_stack.pop
    end

    def current_pos : SourcePos?
      @current_pos
    end

    def current_pos=(pos : SourcePos?) : SourcePos?
      @current_pos = pos
    end

    # Overwrites the top frame in place — backs tail-call collapsing for
    # VM#call's outermost activation (the one real Interpreter::Frame case
    # dispatch_bytecode_call still keeps live, see CallFrame#has_interp_frame):
    # a self-tail-recursive loop of N iterations shows up as ONE frame, not N.
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
    # same phase (a fixed interval of 50 can report 100% of samples on the one
    # instruction that happens to line up with the stride, while an interval of
    # 1, or a jittered interval, both reproduce the expected proportional
    # breakdown).
    # This is the same aliasing hazard any fixed-rate sampler faces against a
    # periodic signal; jittering the phase is the standard fix.

    # A sample key: a {name, instruction, file, line} tuple — file/line
    # nilable since not every instruction resolves a source position (see
    # Chunk#positions).
    alias SampleKey = {String, String, String?, Int32?}

    # The actual counts hash, plus a Mutex, as one object so it can be
    # SHARED BY REFERENCE across every request's own Interpreter under
    # (creme mux) (see `initialize(inherit_from:)` below) — required for
    # profile-scheme to see anything at all when profiling a mux server:
    # each HTTP request runs against its own child Interpreter (mux.cr's own
    # per-request isolation), so without sharing this sink, only the
    # top-level script's own (near-idle, mostly-blocked-on-read-line)
    # Interpreter instance would ever record a sample. The Mutex matters
    # under -Dpreview_mt with more than one OS thread (see mux.cr's own doc
    # comment on request_interpreter) — under the ordinary single-thread/
    # cooperative-Fiber build this project ships by default there's no real
    # concurrent writer, but the lock only taken once per `interval`
    # dispatched instructions (see #tick_sample), never per-instruction, so
    # it costs nothing worth avoiding either way.
    private class SampleSink
      def initialize
        @mutex = Mutex.new
        @counts = {} of SampleKey => Int32
      end

      def record(key : SampleKey) : Nil
        @mutex.synchronize { @counts[key] = (@counts[key]? || 0) + 1 }
      end

      def snapshot : Hash(SampleKey, Int32)
        @mutex.synchronize { @counts.dup }
      end
    end

    # Shared with any child Interpreter spawned (via `inherit_from`) while
    # sampling is active — see SampleSink's own doc comment.
    protected getter sample_sink : SampleSink?

    def start_scheme_sampling(interval_steps : Int32) : Nil
      @sample_interval = interval_steps
      @sample_countdown = jittered_sample_countdown(interval_steps)
      @sample_sink = SampleSink.new
    end

    def stop_scheme_sampling : Hash(SampleKey, Int32)
      sink = @sample_sink
      @sample_interval = nil
      @sample_sink = nil
      sink ? sink.snapshot : {} of SampleKey => Int32
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
      @sample_sink.try(&.record(sample_key(chunk, ip)))
    end

    private def sample_key(chunk : Chunk, ip : Int32) : SampleKey
      pos = chunk.positions[ip]?
      name, instruction = if tag = chunk.sample_tags[ip]?
                            {tag[1], tag[0]}
                          else
                            instr = chunk.instructions[ip]
                            if instr.op == Op::Cxr
                              # Untagged Op::Cxr: decode its bitmap operand back
                              # into the accessor name so the expression column
                              # still shows car/cdr/caar/… under the "cxr" op.
                              {Interpreter.cxr_label(instr.c), "cxr"}
                            else
                              label = Interpreter.op_label(instr.op)
                              {label, label}
                            end
                          end
      {name, instruction, pos.try(&.file), pos.try(&.line)}
    end

    # The KIND of thing an untagged instruction does, in the language's own
    # syntax where one exists (e.g. "+"/"call"/"local-ref") rather than a raw
    # Crystal enum member name — used as both the name and instruction
    # columns for any instruction BytecodeCompiler didn't tag more
    # specifically (see Chunk#sample_tags).
    # Decode an Op::Cxr bitmap operand back into its accessor name, the inverse
    # of bytecode_compiler.cr's cxr_code: bits are innermost-first (1=car/a,
    # 0=cdr/d) below a sentinel top bit, so reading LSB→MSB yields the letters
    # right-to-left; reverse them for the c…r spelling (e.g. 0b1100 → "caddr").
    def self.cxr_label(code : Int32) : String
      letters = [] of Char
      c = code
      while c > 1
        letters << ((c & 1) == 1 ? 'a' : 'd')
        c >>= 1
      end
      "c#{letters.reverse.join}r"
    end

    # ameba:disable Metrics/CyclomaticComplexity
    def self.op_label(op : Op) : String
      case op
      when Op::Add     then "+"
      when Op::Sub     then "-"
      when Op::Mul     then "*"
      when Op::NumLt   then "<"
      when Op::NumLe   then "<="
      when Op::NumGt   then ">"
      when Op::NumGe   then ">="
      when Op::NumEq   then "="
      when Op::VecRef  then "vector-ref"
      when Op::VecSet  then "vector-set!"
      when Op::VecLen  then "vector-length"
      when Op::StrRef  then "string-ref"
      when Op::StrSet  then "string-set!"
      when Op::BvRef   then "bytevector-u8-ref"
      when Op::BvSet   then "bytevector-u8-set!"
      when Op::Cons    then "cons"
      when Op::Not     then "not"
      when Op::IsNull  then "null?"
      when Op::IsPair  then "pair?"
      when Op::Cxr     then "cxr"
      when Op::Abs     then "abs"
      when Op::CmpZero then "cmp-zero"
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

    # `active` is whichever Interpreter's VM call is actually running on
    # THIS fiber right now — NOT necessarily `self`. A builtin's own
    # `interp` parameter is captured once, when the Builtin closure was
    # registered into @global (see builtin_registration.cr's
    # register_module) — normally that's harmless since there's only ever
    # one Interpreter instance in play, so `self` and Interpreter.current
    # always agree. But (creme actor) actors are separate Interpreter
    # instances that deliberately SHARE @global by reference (see
    # Interpreter#initialize(inherit_from:)), so a builtin like map/
    # for-each/apply calling `interp.apply(f, ...)` with its stale captured
    # `interp` would otherwise push the WRONG Interpreter's VM onto this
    # fiber's Interpreter.current stack — corrupting actor-context
    # resolution (self/receive!/monitor/...) for any code nested inside
    # that call. Falls back to `self` if nothing is active yet (e.g. apply
    # called directly from Crystal, outside any VM call).
    def apply(callee : SchemeValue, args : Array(SchemeValue), pos : SourcePos? = nil) : SchemeValue
      active = Interpreter.current || self
      case callee
      when Builtin
        check_arity(callee, args)
        active.push_frame(Frame.new(callee.name, pos))
        begin
          callee.fn.call(args)
        ensure
          active.pop_frame
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
        active.push_frame(Frame.new(callee.chunk.name, pos))
        vm = active.vm_pool.acquire
        begin
          vm.call(callee, args)
        ensure
          active.vm_pool.release(vm)
          active.pop_frame
        end
      when BytecodeCaseClosure
        clause = callee.select_clause(args.size)
        active.push_frame(Frame.new(clause.chunk.name, pos))
        vm = active.vm_pool.acquire
        begin
          vm.call(clause, args)
        ensure
          active.vm_pool.release(vm)
          active.pop_frame
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
        call_env.define(r, Creme.a_to_list(extra))
      end
    end

    # ---- Special-form helpers -------------------------------------------------

    def eval_defmacro(expr : Cons, env : Env) : SchemeValue
      name, mac = build_macro(expr, env)
      env.define(name, mac)
      SchemeSym.of(name)
    end

    # Expand a defmacro call: bind the unevaluated arg forms to the macro's
    # params and run its body (compile + run each form), returning the
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
      body = Creme.list_to_a(formals_rest.cdr)
      raise SchemeRuntimeError.new("defmacro: macro body is empty") if body.empty?
      params, rparam = parse_formals(formals)
      {name.name, Macro.new(params, rparam, body, env, name.name)}
    end

    # Parses a lambda formals spec into {fixed params, rest param (or nil)}:
    # a bare symbol is full-variadic (all args in rest), a proper list is
    # fixed-arity, an improper/dotted list is fixed params plus a rest.
    # Shared by the analyzer (lambda/let/named-let) and build_macro.
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
      env.define(rparam, Creme.a_to_list(vals[params.size..])) if rparam
    end

    private def cond_expand_matches?(requirement : SchemeValue) : Bool
      case requirement
      when SchemeSym
        features.includes?(requirement.name)
      when Cons
        head = requirement.car
        raise SchemeRuntimeError.new("cond-expand: bad requirement") unless head.is_a?(SchemeSym)
        args = Creme.list_to_a(requirement.cdr)
        case head.name
        when "and" then args.all? { |arg| cond_expand_matches?(arg) }
        when "or"  then args.any? { |arg| cond_expand_matches?(arg) }
        when "not"
          raise SchemeRuntimeError.new("cond-expand: not expects 1 argument") unless args.size == 1
          !cond_expand_matches?(args[0])
        when "library"
          raise SchemeRuntimeError.new("cond-expand: library expects 1 argument") unless args.size == 1
          # A library counts as "importable" whether it's already registered
          # (a native family, or a file-based one already imported earlier in
          # this same program) or merely resolvable right now off
          # library_search_path — most R7RS standard names (e.g. (scheme
          # base)) are thin file-based frontends over a native `(creme
          # builtin ...)` family now (see modules/scheme/*.sld) and aren't
          # pre-registered in @libraries until something actually imports
          # them, so a plain has_key? check alone would wrongly report a
          # perfectly importable library as absent. resolve_library has the
          # useful side effect of actually registering it on success, same
          # as a real import would.
          libname = SchemeLibrary.parse_library_name(args[0])
          return false if emitting_for_cvm && libname.size == 3 && libname[0] == "creme" && libname[1] == "builtin"
          @libraries.has_key?(libname) || !!(resolve_library(libname) rescue nil)
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
