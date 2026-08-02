# ===========================================================================
# process module: running external commands, program arguments
# ===========================================================================
#
# ProcessLibrary holds command-line — the one procedure R7RS's
# (scheme process-context) shares with this module — so (scheme
# process-context) (modules/scheme/process_context.cr) registers it directly
# and derives its exports. ProcessExtra holds the creme-only process-run;
# (creme process) registers BOTH.

module Scheme::Builtins::ProcessLibrary
  extend self
  include Scheme::BuiltinHelpers

  # R7RS-exact name/contract: (command-line) -> list of strings, whose
  # first element is the program name. This module's Crystal-native ARGV
  # doesn't include the program name, so it's prepended here.
  @[Scheme::SchemeFn("command-line", min: 0, max: 0)]
  def command_line(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    Scheme.a_to_list(([PROGRAM_NAME] + ARGV).map { |arg| SchemeStr.new(arg).as(SchemeValue) })
  end
end

# creme-only process control, beyond R7RS's (scheme process-context) contract.
module Scheme::Builtins::ProcessExtra
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("process-run", min: 2, max: 2)]
  def process_run(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    cmd = args[0]
    raise SchemeRuntimeError.new("process-run: expected string command, got #{cmd.write_string}") unless cmd.is_a?(SchemeStr)
    cmd_args = Scheme.list_to_a(args[1]).map do |elem|
      raise SchemeRuntimeError.new("process-run: expected list of strings, got #{elem.write_string}") unless elem.is_a?(SchemeStr)
      elem.value
    end

    stdout_io = IO::Memory.new
    stderr_io = IO::Memory.new
    begin
      status = ::Process.run(cmd.value, cmd_args, output: stdout_io, error: stderr_io)
    rescue ex : Exception
      raise SchemeRuntimeError.new("process-run: #{ex.message}")
    end

    # returns (stdout stderr status success) — use car/cadr/caddr/cadddr to destructure
    Scheme.a_to_list([
      SchemeStr.new(stdout_io.to_s).as(SchemeValue),
      SchemeStr.new(stderr_io.to_s).as(SchemeValue),
      SchemeInt.new(status.exit_code.to_i64).as(SchemeValue),
      SchemeBool.of(status.success?).as(SchemeValue),
    ])
  end

  # ---------------------------------------------------------------------
  # process-spawn / process-alive? / process-kill! / process-wait! —
  # non-blocking process management built on Crystal's Process.new (NOT
  # Process.run, which blocks until exit, and which process-run above
  # exists for). A spawned Process object is kept alive in @@handles,
  # keyed by pid, both so it can be looked up again by
  # process-alive?/process-kill!/process-wait!, and so its own @input
  # ivar (the write end of a 'stdin 'keep-open pipe, if any) stays
  # reachable -- letting it become unreachable would let Crystal's GC
  # finalize (and thus close) that write end, handing the child an
  # unwanted EOF on stdin.
  #
  # @@handles is a plain class variable, not an Interpreter ivar, despite
  # this codebase's usual rule that shared *mutable* builtin state must
  # live on Interpreter (see (creme random)'s random_rng)
  # to avoid leaking across sandboxed Interpreter instances. That rule
  # protects *simulated* per-interpreter state (a seeded RNG stream, where
  # two sandboxes must diverge). A spawned OS child is not simulated
  # state: its pid is assigned by the kernel's single, process-wide pid
  # table, and two Interpreter instances running inside the same OS
  # process are -- by construction -- the same OS process sharing that
  # same table (same reasoning (creme actor)'s @@nodes/@@mutex and (creme
  # raft)'s @@namespace_counter already rely on for their own process-wide
  # state).
  @@handles = {} of Int64 => ::Process
  @@handles_mutex = Mutex.new

  private record SpawnOptions,
    env : Hash(String, String)?,
    chdir : String?,
    stdout_io : ::Process::Stdio,
    stderr_io : ::Process::Stdio,
    stdin_redirect : ::Process::Stdio

  # (process-spawn cmd args . kvs) -> pid (SchemeInt), returns immediately
  # without waiting for the child. `kvs` is the same flat 'keyword value
  # ... convention (sql-open)'s 'reader/'writer args use:
  #   'env ALIST       -- extra/override env vars, alist of (string . string)
  #                       pairs, MERGED on top of this process's own full
  #                       environment (Process.new's clear_env: false
  #                       default) -- not a replacement environment.
  #   'chdir STRING    -- child's working directory (default: inherited).
  #   'stdout STRING   -- file path; opened for writing (create/truncate,
  #                       like shell `>`) and used as the child's stdout.
  #                       Default (omitted): a real open /dev/null file,
  #                       NOT Process::Redirect::Close -- some programs
  #                       treat a fully-closed stdout fd as an error
  #                       (write(2) -> EBADF) rather than silently
  #                       succeeding against /dev/null.
  #   'stderr STRING   -- same as 'stdout, for the child's stderr.
  #   'stdin SYMBOL    -- one of:
  #     'closed (default) -- child's stdin is an open, empty /dev/null.
  #     'inherit           -- child shares this process's own stdin.
  #     'keep-open         -- child's stdin is the read end of a fresh
  #                          pipe whose write end this process holds onto
  #                          (via @@handles) and DELIBERATELY never writes
  #                          to or closes -- the child's read() on stdin
  #                          then blocks forever with no EOF, replacing
  #                          the old `tail -f /dev/null |` trick with no
  #                          extra process at all.
  @[Scheme::SchemeFn("process-spawn", min: 2, max: -1)]
  def process_spawn(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    cmd = string_arg(args[0], "process-spawn")
    cmd_args = Scheme.list_to_a(args[1]).map { |elem| string_arg(elem, "process-spawn") }
    opts = spawn_kv_args(args[2..-1], "process-spawn")

    process =
      begin
        ::Process.new(cmd, cmd_args,
          env: opts.env, chdir: opts.chdir, clear_env: false,
          input: opts.stdin_redirect, output: opts.stdout_io, error: opts.stderr_io)
      rescue ex : Exception
        raise SchemeRuntimeError.new("process-spawn: #{ex.message}")
      end

    @@handles_mutex.synchronize { @@handles[process.pid] = process }
    SchemeInt.new(process.pid)
  end

  private def spawn_kv_args(rest : Array(SchemeValue), who : String) : SpawnOptions
    raise SchemeRuntimeError.new("#{who}: keyword arguments must come in 'keyword value pairs") if rest.size.odd?
    env = nil
    chdir = nil
    stdout_path = nil
    stderr_path = nil
    stdin_mode = "closed"
    rest.each_slice(2) do |pair|
      key, value = pair[0], pair[1]
      raise SchemeRuntimeError.new("#{who}: expected a keyword symbol, got #{key.write_string}") unless key.is_a?(SchemeSym)
      case key.name
      when "env"    then env = spawn_env_alist(value, who)
      when "chdir"  then chdir = string_arg(value, who)
      when "stdout" then stdout_path = string_arg(value, who)
      when "stderr" then stderr_path = string_arg(value, who)
      when "stdin"  then stdin_mode = spawn_stdin_symbol(value, who)
      else
        raise SchemeRuntimeError.new("#{who}: unknown keyword '#{key.name} (expected 'env, 'chdir, 'stdout, 'stderr, or 'stdin)")
      end
    end

    stdin_redirect =
      case stdin_mode
      when "inherit"   then ::Process::Redirect::Inherit.as(::Process::Stdio)
      when "keep-open" then ::Process::Redirect::Pipe.as(::Process::Stdio)
      else                  spawn_devnull(who, "r")
      end

    SpawnOptions.new(env, chdir, spawn_output_redirect(stdout_path, who), spawn_output_redirect(stderr_path, who), stdin_redirect)
  end

  private def spawn_output_redirect(path : String?, who : String) : ::Process::Stdio
    return spawn_devnull(who, "w") unless path
    begin
      ::File.open(path, "w").as(::Process::Stdio)
    rescue ex : Exception
      raise SchemeRuntimeError.new("#{who}: could not open '#{path}' for writing: #{ex.message}")
    end
  end

  private def spawn_devnull(who : String, mode : String) : ::Process::Stdio
    ::File.open(::File::NULL, mode).as(::Process::Stdio)
  rescue ex : Exception
    raise SchemeRuntimeError.new("#{who}: could not open #{::File::NULL}: #{ex.message}")
  end

  private def spawn_env_alist(v : SchemeValue, who : String) : Hash(String, String)
    raise SchemeRuntimeError.new("#{who}: expected 'env alist, got #{v.write_string}") unless Scheme.proper_list?(v)
    env = {} of String => String
    Scheme.list_to_a(v).each do |entry|
      raise SchemeRuntimeError.new("#{who}: expected (name . value) pair in 'env, got #{entry.write_string}") unless entry.is_a?(Cons)
      env[string_arg(entry.car, who)] = string_arg(entry.cdr, who)
    end
    env
  end

  private def spawn_stdin_symbol(v : SchemeValue, who : String) : String
    raise SchemeRuntimeError.new("#{who}: 'stdin expects a symbol ('closed, 'inherit, or 'keep-open), got #{v.write_string}") unless v.is_a?(SchemeSym)
    case v.name
    when "closed", "inherit", "keep-open" then v.name
    else                                       raise SchemeRuntimeError.new("#{who}: unknown 'stdin mode '#{v.name} (expected 'closed, 'inherit, or 'keep-open)")
    end
  end

  # (process-alive? pid) -> #t/#f. Uses Process.exists?, a real stdlib
  # class method (kill(pid, 0) under the hood on POSIX) -- works for ANY
  # pid, not just ones spawned via process-spawn, mirroring how a shell's
  # own `kill -0 pid` works on an arbitrary pid.
  @[Scheme::SchemeFn("process-alive?", min: 1, max: 1)]
  def process_alive(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    pid = int_arg(args[0], "process-alive?")
    SchemeBool.of(::Process.exists?(pid))
  end

  # (process-kill! pid . kvs) -> #t/#f (was a live process actually
  # found and signaled?). 'signal SYMBOL-or-NUMBER: one of the symbols
  # 'term (default), 'kill, 'int, OR a raw signal number (e.g. 9 for
  # SIGKILL, 2 for SIGINT) for any signal this project doesn't name a
  # symbol for. Idempotent: signaling an already-dead pid returns #f
  # rather than raising, matching pkill's own behavior. Does NOT itself
  # block or reap -- Crystal's own global SIGCHLD handler reaps every
  # child asynchronously the instant it exits regardless of whether
  # process-wait! is ever called, so there's no zombie-accumulation
  # concern to work around here; this builtin only ever sends a signal.
  @[Scheme::SchemeFn("process-kill!", min: 1, max: -1)]
  def process_kill(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    pid = int_arg(args[0], "process-kill!")
    sig = kill_signal_arg(args[1..-1], "process-kill!")
    return SchemeBool.of(false) unless ::Process.exists?(pid)
    begin
      ::Process.signal(sig, pid)
    rescue ex : Exception
      # Process already exited between the exists? check and the signal
      # (an inherent TOCTOU race with any external process) -- treat the
      # same as "nothing to kill", not an error, exactly like pkill would.
      return SchemeBool.of(false)
    end
    SchemeBool.of(true)
  end

  private def kill_signal_arg(rest : Array(SchemeValue), who : String) : Signal
    raise SchemeRuntimeError.new("#{who}: keyword arguments must come in 'keyword value pairs") if rest.size.odd?
    sig = Signal::TERM
    rest.each_slice(2) do |pair|
      key, value = pair[0], pair[1]
      raise SchemeRuntimeError.new("#{who}: expected a keyword symbol, got #{key.write_string}") unless key.is_a?(SchemeSym)
      raise SchemeRuntimeError.new("#{who}: unknown keyword '#{key.name} (expected 'signal)") unless key.name == "signal"
      sig = case value
            when SchemeSym
              case value.name
              when "term" then Signal::TERM
              when "kill" then Signal::KILL
              when "int"  then Signal::INT
              else             raise SchemeRuntimeError.new("#{who}: unknown 'signal '#{value.name} (expected 'term, 'kill, 'int, or a signal number)")
              end
            when SchemeInt
              Signal.new(value.value.to_i32)
            else
              raise SchemeRuntimeError.new("#{who}: 'signal expects a symbol ('term, 'kill, or 'int) or a signal number, got #{value.write_string}")
            end
    end
    sig
  end

  # (process-write-line! pid line) -> unspecified. Writes line followed by
  # a newline to the child's stdin and flushes -- the one legitimate use
  # for 'keep-open's otherwise-untouched write end (see process-spawn's
  # own doc comment): waking a child that's blocking on its own (read-line)
  # as a "wait until told to stop" signal, so it can shut down gracefully
  # (e.g. competition/scheme/demo-todo/app.scm under --profile, woken by
  # competition/bench.scm's --profile so the app can print/flush its
  # profile report and exit instead of being killed outright via
  # process-kill!). Raises if pid was never spawned via process-spawn (or
  # was already waited on), or if its stdin wasn't opened with 'keep-open
  # (i.e. there is no write end to write to).
  @[Scheme::SchemeFn("process-write-line!", min: 2, max: 2)]
  def process_write_line(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    pid = int_arg(args[0], "process-write-line!")
    line = string_arg(args[1], "process-write-line!")
    process = @@handles_mutex.synchronize { @@handles[pid]? }
    raise SchemeRuntimeError.new("process-write-line!: pid #{pid} was not spawned via process-spawn, or was already waited on") unless process
    begin
      process.input.puts(line)
      process.input.flush
    rescue ex : Exception
      raise SchemeRuntimeError.new("process-write-line!: #{ex.message}")
    end
    NIL.as(SchemeValue)
  end

  # (process-wait! pid) -> exit code (SchemeInt), blocking until that
  # pid (which MUST have been spawned via process-spawn -- this is what
  # lets us find its live Process object and call #wait on it) exits.
  # Raises if pid was never spawned via process-spawn, or was already
  # waited on (and thus removed from @@handles). A process killed by a
  # signal (e.g. via process-kill!) has no ordinary exit code -- #exit_code
  # raises "Abnormal exit has no exit code" in that case, so this reports
  # the negative signal value instead (-15 for SIGTERM, -9 for SIGKILL,
  # ...), the same convention many shells' own `$?` use for a signaled
  # child.
  @[Scheme::SchemeFn("process-wait!", min: 1, max: 1)]
  def process_wait(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    pid = int_arg(args[0], "process-wait!")
    process = @@handles_mutex.synchronize { @@handles.delete(pid) }
    raise SchemeRuntimeError.new("process-wait!: pid #{pid} was not spawned via process-spawn, or was already waited on") unless process
    status =
      begin
        process.wait
      rescue ex : Exception
        raise SchemeRuntimeError.new("process-wait!: #{ex.message}")
      end
    code = status.exit_code? || -(status.exit_signal?.try(&.value) || 0)
    SchemeInt.new(code.to_i64)
  end

  # (sleep! seconds) -> blocks the current fiber (NOT the whole OS
  # process/thread -- Crystal's sleep(Time::Span) suspends only the
  # calling fiber via the event loop) for `seconds`, an exact integer or
  # any inexact/rational real number of seconds. Replaces bench.scm's old
  # (process-run "sleep" (list seconds-as-string)) hack -- no subprocess.
  @[Scheme::SchemeFn("sleep!", min: 1, max: 1)]
  def sleep_bang(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    seconds = Scheme.as_f64(args[0], "sleep!")
    raise SchemeRuntimeError.new("sleep!: seconds must be non-negative") if seconds < 0
    sleep(seconds.seconds)
    NIL.as(SchemeValue)
  end

  # (sleep-ms! milliseconds) -> same fiber-yielding sleep! above, but
  # takes an exact integer count of milliseconds instead of a real number
  # of seconds. Exists so portable Scheme code (written to run unchanged
  # under both this interpreter and cvm/'s own sleep-ms!, which only has
  # an integer-milliseconds C API) never needs two timer call sites --
  # see (creme raft-scheme)'s election/heartbeat tickers, the first
  # caller of this.
  @[Scheme::SchemeFn("sleep-ms!", min: 1, max: 1)]
  def sleep_ms_bang(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    ms = int_arg(args[0], "sleep-ms!")
    raise SchemeRuntimeError.new("sleep-ms!: milliseconds must be non-negative") if ms < 0
    sleep(ms.milliseconds)
    NIL.as(SchemeValue)
  end
end

module Scheme
  class Interpreter
    register_library ["creme", "builtin", "process"] do |env|
      register_module(Scheme::Builtins::ProcessLibrary, env) +
        register_module(Scheme::Builtins::ProcessExtra, env)
    end
  end
end
