require "./scheme"

def format_error(ex : Scheme::SchemeError) : String
  String.build do |io|
    if pos = ex.pos
      io << "Error: " << ex.message << " (" << pos.file << ':' << pos.line << ':' << pos.col << ')'
    else
      io << "Error: " << ex.message
    end
    ex.frames.reverse_each do |frame|
      next if frame.name.empty?
      io << '\n' << "  at " << frame.name
      if fp = frame.pos
        io << " (" << fp.file << ':' << fp.line << ':' << fp.col << ')'
      end
    end
  end
end

def repl(interp : Scheme::Interpreter) : Nil
  buffer = ""
  loop do
    prompt = buffer.empty? ? "scheme> " : "   ...  "
    print(prompt)
    line = STDIN.gets(chomp: false)
    if line.nil?
      puts
      break
    end
    buffer = buffer.empty? ? line : buffer + line
    next if buffer.strip.empty?

    begin
      forms = Scheme::Reader.read_all(buffer, "<repl>")
      buffer = ""
      forms.each do |form|
        result = Scheme::BytecodeCompiler.run_program(interp, [form], interp.global)
        puts result.write_string
      end
    rescue Scheme::SchemeIncompleteError
      # keep buffer, request continuation
      next
    rescue ex : Scheme::SchemeExit
      exit(ex.code)
    rescue ex : Scheme::SchemeError
      buffer = ""
      puts format_error(ex)
    rescue ex
      buffer = ""
      puts "Internal error: #{ex.message}"
    end
  end
end

def usage : Nil
  puts <<-USAGE
  creme — a Scheme interpreter (Crystal)

  Usage:
    creme                        Start the interactive REPL
    creme <file.scm>             Execute a Scheme source file
    creme -- <file.scm> [args...]
                                 Same as `creme <file.scm> [args...]`, but
                                 guarantees <file.scm> is treated as a
                                 plain script path even if it happens to
                                 look like one of creme's own flags below
                                 (e.g. a script literally named
                                 "--profile"). Only ever needed for the
                                 path itself — an ordinary arg like
                                 "--profile" appearing after the path
                                 already reaches the script untouched.
    creme -S | --dump-bytecode [--strict] <file.scm>
                                 Compile a script and print its bytecode
                                 disassembly (one dump per top-level form,
                                 including nested closures) instead of
                                 running it. (scheme base)/(scheme write) are
                                 auto-imported by default (matching the REPL,
                                 and what a real run of the script would
                                 fuse) — pass --strict for the plain-R7RS
                                 behavior of requiring the script's own
                                 (import ...), e.g. to see exactly what an
                                 unfused/not-yet-imported form compiles to
    creme --profile table <file.scm> [args...]
                                 Run a script exactly as `creme <file.scm>
                                 [args...]` would, but with the whole run
                                 wrapped in (creme bench)'s profiling —
                                 both of (creme prof)'s samplers (a native
                                 SIGPROF sampler and the interpreter's own
                                 cooperative step-counted one), nested in
                                 one execution the same way (creme bench)'s
                                 own profile-workload does — printing the
                                 combined report to stdout right after the
                                 script naturally finishes (e.g. after a
                                 server's own (read-line) unblocks). "table"
                                 is currently the only supported report
                                 format (a future format, e.g. "html", could
                                 be added as another value here without
                                 changing this flag's shape)
    creme --emit-cvm <file.scm> <out.cvmc>
                                 Compile a script and serialize its bytecode
                                 to <out.cvmc> for the standalone C11
                                 prototype VM in cvm/ (see cvm/README.md) —
                                 a narrow experiment, not a general target;
                                 currently only bench/creme.scm is verified
                                 to work with it.
    creme --cvm <file.scm>
                                 Shorthand for --emit-cvm to a throwaway
                                 file followed by `cvm/cvm <that file>` —
                                 compiles <file.scm> and runs it under the
                                 standalone C prototype VM in one step,
                                 cleaning up the intermediate .cvmc file
                                 afterward. Must be run from the repo root
                                 with cvm/cvm already built (`make -C cvm`),
                                 matching bench/bench.scm's own convention
                                 for locating it.
    creme --profile --cvm <file.scm>
                                 Same as --cvm above, but runs
                                 `cvm/cvm --profile <that file>` (see
                                 cvm/README.md's "Profiling" section)
                                 instead of a plain run.
    creme --help | -h            Show this help
  USAGE
end

# Compiles and runs each top-level form of `path`, printing its bytecode
# disassembly before running it — for `creme --dump-bytecode`. Runs (rather
# than just compiling) since a later form's analyze pass needs any earlier
# define-syntax/import to have actually executed first, matching
# Scheme.run_file's own incremental per-form driver. Auto-imports (scheme
# base)/(scheme write) by default (like the REPL) so the dump reflects what a
# real run actually compiles to — notably so arithmetic/cxr/etc. fuse into
# their PrimCallNode specializations (analyzer.cr's analyze_app requires the
# callee to already resolve to the real Builtin at analyze time) instead of
# showing a plain unfused CallGlobal just because the script hasn't
# (import (scheme base)) of its own yet. `strict: true` opts back into plain
# R7RS behavior (no auto-import) for scripts that manage their own imports
# and want to see exactly what they compile to before any import runs.
#
# Uses Scheme.forms_for (not a bare Reader.read_all) so a `#lang` file (e.g.
# a `#lang (creme syntax sql)` query) is disassembled the same way running it
# actually would be — via its own dialect's read_program, whatever generated
# code that produces — rather than failing outright on `#lang` as unknown `#`
# syntax. A plain (non-`#lang`) script is unaffected either way, since
# forms_for falls through to the ordinary Reader for it.
def dump_bytecode(path : String, strict : Bool = false) : Nil
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"], auto_import_base: !strict)
  src = File.read(path)
  forms = Scheme.forms_for(interp, src, path)
  forms.each_with_index do |form, i|
    node = interp.analyze(form, interp.global)
    chunk = Scheme::BytecodeCompiler.compile_program([node])
    puts "; ---- top-level form #{i} ----" if forms.size > 1
    Scheme::Disassembler.disassemble(chunk, "form #{i}")
    Scheme::VM.new(interp, interp.global).run(chunk)
  end
end

# Compiles `path` (same auto-import-base convention as dump_bytecode above,
# so builtins fuse the same way a real run would) into a single Chunk and
# serializes it to `out_path` via CVMEmitter/ChunkSerializer (the same
# "SCB1" format the real Crystal VM already round-trips through) — for
# `creme --emit-cvm`, feeding the standalone C11 prototype VM in cvm/ (see
# cvm/README.md for current opcode/value-model coverage). Pushes path's own
# directory first, same as Scheme.run_file — bench/creme.scm's own
# `(include "workloads.scm")` resolves relative to wherever the script
# lives, not the process's CWD, so this must match run_file's convention
# rather than dump_bytecode's (which doesn't push one at all) for `creme
# --emit-cvm bench/creme.scm ...` to work when invoked from the repo root.
def emit_cvm(path : String, out_path : String) : Nil
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"], auto_import_base: true)
  interp.push_load_dir(File.dirname(File.expand_path(path)))
  begin
    src = File.read(path)
    forms = Scheme.forms_for(interp, src, path)
    bytes = Scheme::CVMEmitter.emit(interp, forms, interp.global)
    File.write(out_path, bytes)
  ensure
    interp.pop_load_dir
  end
end

# Handles `creme --emit-cvm <file.scm> <out.cvmc>` — split out of `main`
# purely to keep that method's own top-level dispatch simple.
def handle_emit_cvm(args : Array(String)) : Nil
  unless args[1]? && args[2]?
    STDERR.puts "Usage: creme --emit-cvm <file.scm> <out.cvmc>"
    exit 1
  end
  begin
    path = args[1]
    out_path = args[2]
    emit_cvm(path, out_path)
  rescue ex : Scheme::SchemeError
    STDERR.puts format_error(ex)
    exit 1
  rescue ex
    STDERR.puts "Internal error: #{ex.message}"
    exit 1
  end
end

# Shared by `creme --cvm <file.scm>` and `creme --profile --cvm <file.scm>`:
# emits <file.scm> to a throwaway .cvmc file, runs it via cvm/cvm (with
# `cvm_args` — e.g. ["--profile"], or [] for a plain run — passed ahead of
# the compiled file's own path), then cleans up the intermediate file.
# Assumes the repo-root-relative "cvm/cvm" path, same convention
# bench/bench.scm's own run-variant calls rely on for locating it.
def run_via_cvm(path : String, cvm_args : Array(String)) : Nil
  cvm_bin = "cvm/cvm"
  unless File.exists?(cvm_bin)
    STDERR.puts "creme: #{cvm_bin} not found — build it first (`make -C cvm`)"
    exit 1
  end

  tmp_path = File.tempname("creme-cvm", ".cvmc")
  exit_code = 1
  begin
    emit_cvm(path, tmp_path)
    status = Process.run(cvm_bin, cvm_args + [tmp_path],
      output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
    exit_code = status.exit_code
  rescue ex : Scheme::SchemeError
    STDERR.puts format_error(ex)
  rescue ex
    STDERR.puts "Internal error: #{ex.message}"
  ensure
    File.delete(tmp_path) if File.exists?(tmp_path)
  end
  exit(exit_code)
end

# Handles `creme --cvm <file.scm>` — combines --emit-cvm (to a throwaway
# file) with a plain `cvm/cvm <that file>` run, so running a script under the
# C prototype VM doesn't need its own separate compile-then-run step. Split
# out of `main` purely to keep that method's own top-level dispatch simple.
def handle_cvm(args : Array(String)) : Nil
  unless path = args[1]?
    STDERR.puts "Usage: creme --cvm <file.scm>"
    exit 1
  end
  run_via_cvm(path, [] of String)
end

# Handles `creme --profile --cvm <file.scm>` — same as --cvm above, but runs
# cvm/cvm with --profile (see cvm/README.md's "Profiling" section). Split out
# of `main` purely to keep that method's own top-level dispatch simple.
def handle_profile_cvm(args : Array(String)) : Nil
  unless path = args[2]?
    STDERR.puts "Usage: creme --profile --cvm <file.scm>"
    exit 1
  end
  run_via_cvm(path, ["--profile"])
end

# Handles `creme -S | --dump-bytecode [--strict] <file.scm>` — split out of
# `main` purely to keep that method's own top-level dispatch simple.
def handle_dump_bytecode(args : Array(String)) : Nil
  strict = args[1]? == "--strict"
  path_index = strict ? 2 : 1
  unless args[path_index]?
    STDERR.puts "Usage: creme --dump-bytecode <file.scm>"
    exit 1
  end
  begin
    # Drop the dump-bytecode flag itself (and --strict, if given) from
    # ARGV before compiling — (command-line)/(creme cli) (see
    # modules/creme/cli.sld) assume ARGV[0] is always the script's own
    # path, matching plain "creme SCRIPT [args...]"; leaving
    # "-S"/"--dump-bytecode"/"--strict" in ARGV would shift that and make
    # the script's own flag parsing see its path as a stray unrecognized
    # flag. `args` IS `ARGV` (see main's own call site), so this shift is
    # visible to both.
    path = args[path_index]
    path_index.times { ARGV.shift }
    dump_bytecode(path, strict)
  rescue ex : Scheme::SchemeExit
    exit(ex.code)
  rescue ex : Scheme::SchemeError
    STDERR.puts format_error(ex)
    exit 1
  end
end

# Handles `creme --profile table <file.scm> [args...]` — centralizes a
# `(if profile? (profile (lambda () (set! scheme-report (profile-scheme
# (lambda () (wait-for-stop!)) 200)))) ...)`-shaped block several scripts
# (competition/scheme/demo-todo/app.scm, competition/scheme/demo-todo-dsl/
# app.mex) used to hand-roll themselves, checking (command-line) for their
# own "--profile" flag. Runs a small wrapper program that `load`s the real
# script as the profiled thunk — `load` (src/scheme/modules/scheme/
# load.cr) resolves/pushes the target's own directory exactly like
# Scheme.run_file does, and respects a `#lang` header exactly the same
# way too, so this works identically to a plain `creme <file.scm>` run
# other than the profiling wrapper and report. Split out of `main` purely
# to keep that method's own top-level dispatch simple.
def handle_profile(args : Array(String)) : Nil
  unless args[1]? == "table"
    STDERR.puts "Usage: creme --profile table <file.scm> [args...]"
    exit 1
  end
  unless path = args[2]?
    STDERR.puts "Usage: creme --profile table <file.scm> [args...]"
    exit 1
  end
  begin
    # Drop "--profile table" from ARGV, same reason/mechanism as
    # --dump-bytecode/--strict above — (command-line)/(creme cli) assume
    # ARGV[0] is the script's own path.
    2.times { ARGV.shift }
    interp = Scheme::Interpreter.new(library_search_path: ["./modules"], auto_import_base: false)
    wrapper = <<-SCHEME
      (import (scheme base) (scheme write) (scheme load) (creme prof) (creme bench))
      (define scheme-report #f)
      (define crystal-report
        (profile (lambda ()
                   (set! scheme-report (profile-scheme (lambda () (load #{path.inspect})) 200)))))
      (display
       (profile-report->string
        (list (cons "name" #{path.inspect})
              (cons "repeat" 1)
              (cons "scheme-report" scheme-report)
              (cons "crystal-report" crystal-report)
              (cons "scheme-total" (profile-scheme-total-samples scheme-report))
              (cons "crystal-total" (profile-total-samples crystal-report)))))
      (newline)
      SCHEME
    Scheme.run_source(interp, wrapper, source_name: path)
  rescue ex : Scheme::SchemeExit
    exit(ex.code)
  rescue ex : Scheme::SchemeError
    STDERR.puts format_error(ex)
    exit 1
  rescue ex
    STDERR.puts "Internal error: #{ex.message}"
    exit 1
  end
end

# A piped/non-interactive script (STDIN isn't a TTY, no file argument) is a
# program like any other — it must explicitly (import (scheme base)) etc.,
# matching strict R7RS and the same contract file execution has (see main's
# args[0] branch). Split out of `main` purely to keep its own dispatch simple.
def run_piped_script : Nil
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"], auto_import_base: false)
  src = STDIN.gets_to_end
  Scheme::BytecodeCompiler.run_program(interp, Scheme::Reader.read_all(src, "<stdin>"), interp.global)
rescue ex : Scheme::SchemeExit
  exit(ex.code)
rescue ex : Scheme::SchemeError
  STDERR.puts format_error(ex)
  exit 1
rescue ex
  STDERR.puts "Internal error: #{ex.message}"
  exit 1
end

# Runs `path` as an ordinary script, exactly like plain `creme path
# [args...]` — shared by main's plain `args[0]` case and the `--` escape
# hatch below, so there is exactly one place that owns this rescue/import
# behavior.
def run_script(path : String) : Nil
  # A script file must explicitly import what it uses, per R7RS — see the
  # auto_import_base doc comment on Interpreter#initialize.
  Scheme.run_file(Scheme::Interpreter.new(library_search_path: ["./modules"], auto_import_base: false), path)
rescue ex : Scheme::SchemeExit
  exit(ex.code)
rescue ex : Scheme::SchemeError
  STDERR.puts format_error(ex)
  exit 1
rescue ex
  STDERR.puts "Internal error: #{ex.message}"
  exit 1
end

def main : Nil
  args = ARGV
  if args.empty?
    if STDIN.tty?
      # Interactive REPL: batteries-included, matching this project's
      # established ergonomics — (scheme base)/(scheme write) are
      # auto-imported so there's no friction typing expressions live.
      interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
      puts "creme — Crystal Scheme interpreter. Ctrl-D or (exit) to quit."
      repl(interp)
    else
      run_piped_script
    end
    return
  end

  case args[0]
  when "--"
    # Escape hatch: `creme -- <file.scm> [args...]` always runs <file.scm>
    # as a plain script, even if it (or an arg after it) happens to look
    # like "--help"/"--dump-bytecode"/"--profile" — e.g. handing a script
    # its own "--profile" flag (for the script's own unrelated purposes)
    # without creme's own --profile table wrapper intercepting it: `creme
    # -- myscript.scm --profile`. Only args[0] is special-cased below, so
    # this is only needed when the SCRIPT PATH itself would otherwise be
    # misread as one of creme's own flags; a literal "--profile" anywhere
    # after the path already passes through untouched (see handle_profile).
    unless path = args[1]?
      STDERR.puts "Usage: creme -- <file.scm> [args...]"
      exit 1
    end
    ARGV.shift # drop the "--" marker; ARGV[0] becomes the script's own path
    run_script(path)
  when "--help", "-h"
    usage
  when "--dump-bytecode", "-S"
    handle_dump_bytecode(args)
  when "--emit-cvm"
    handle_emit_cvm(args)
  when "--cvm"
    handle_cvm(args)
  when "--profile"
    if args[1]? == "--cvm"
      handle_profile_cvm(args)
    else
      handle_profile(args)
    end
  else
    run_script(args[0])
  end
end

main
