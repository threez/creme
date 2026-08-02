require "./creme"

# Reopens the stdlib's own `lib LibGC` (crystal/gc/boehm.cr) just to add the
# two bdwgc functions it doesn't already bind, needed for the default-heap-
# size tuning below -- see icecreme/main.c's own equivalent GC_INIT()-adjacent
# comment (same rationale, same libgc, same measured effect) for why.
lib LibGC
  fun expand_hp = GC_expand_hp(bytes : LibC::SizeT) : LibC::Int
  fun get_heap_size = GC_get_heap_size : LibC::SizeT
end

def format_error(ex : Creme::SchemeError) : String
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

# # The interactive REPL is now the same shared (creme repl) library
# # (modules/creme/repl.sld) that icecreme/repl.scm and --self-hosted mode also
# # delegate to, instead of Crystal-native hand-rolled line-reading/
# # buffering/error-formatting -- one implementation for line-editing,
# # live syntax highlighting, and paren-matching across all three runtimes.
def repl(interp : Creme::Interpreter) : Nil
  Creme.run_source(interp, "(import (scheme process-context)) (import (creme repl)) (run-repl)")
rescue ex : Creme::SchemeExit
  exit(ex.code)
rescue ex : Creme::SchemeError
  STDERR.puts format_error(ex)
  exit 1
rescue ex
  STDERR.puts "Internal error: #{ex.message}"
  exit 1
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
    creme --disassemble <file.ice>
                                 Disassemble an ALREADY-COMPILED ICE1 file
                                 (e.g. one written by --emit-icecreme, or
                                 compiled by the self-hosted (creme
                                 compiler compiler)'s own compile-source-
                                 to-bytes) — unlike -S/--dump-bytecode
                                 above, does not recompile from source; it
                                 reads the file's own raw bytes through the
                                 exact same deserializer load-chunk-bytes
                                 and icecreme both use, so what it prints is
                                 exactly what would actually run
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
    creme --emit-icecreme <file.scm> <out.ice>
                                 Compile a script and serialize its bytecode
                                 to <out.ice> for the standalone C11
                                 prototype VM in icecreme/ (see icecreme/README.md) —
                                 a narrow experiment, not a general target;
                                 currently only bench/creme.scm is verified
                                 to work with it.
    creme --icecreme <file.scm>
                                 Shorthand for --emit-icecreme to a throwaway
                                 file followed by `icecreme/icecreme <that file>` —
                                 compiles <file.scm> and runs it under the
                                 standalone C prototype VM in one step,
                                 cleaning up the intermediate .ice file
                                 afterward. Must be run from the repo root
                                 with icecreme/icecreme already built (`make -C icecreme`),
                                 matching bench/bench.scm's own convention
                                 for locating it.
    creme --profile --icecreme <file.scm>
                                 Same as --icecreme above, but runs
                                 `icecreme/icecreme --profile <that file>` (see
                                 icecreme/README.md's "Profiling" section)
                                 instead of a plain run.
    creme --self-hosted <file.scm>
                                 Run <file.scm> exactly like plain `creme
                                 <file.scm>`, but compiled by the self-
                                 hosted Scheme-to-bytecode compiler
                                 ((creme compiler compiler), see modules/
                                 creme/compiler/compiler.sld) instead of
                                 the native Crystal BytecodeCompiler, then
                                 run on the SAME real Crystal VM either
                                 way — an opt-in way to exercise/benchmark
                                 the self-hosted compiler on a real script
                                 without it being the interpreter's
                                 default execution path.
    creme --help | -h            Show this help
  USAGE
end

# Compiles and runs each top-level form of `path`, printing its bytecode
# disassembly before running it — for `creme --dump-bytecode`. Runs (rather
# than just compiling) since a later form's analyze pass needs any earlier
# define-syntax/import to have actually executed first, matching
# Creme.run_file's own incremental per-form driver. Auto-imports (scheme
# base)/(scheme write) by default (like the REPL) so the dump reflects what a
# real run actually compiles to — notably so arithmetic/cxr/etc. fuse into
# their PrimCallNode specializations (analyzer.cr's analyze_app requires the
# callee to already resolve to the real Builtin at analyze time) instead of
# showing a plain unfused CallGlobal just because the script hasn't
# (import (scheme base)) of its own yet. `strict: true` opts back into plain
# R7RS behavior (no auto-import) for scripts that manage their own imports
# and want to see exactly what they compile to before any import runs.
#
# Uses Creme.forms_for (not a bare Reader.read_all) so a `#lang` file (e.g.
# a `#lang (creme syntax sql)` query) is disassembled the same way running it
# actually would be — via its own dialect's read_program, whatever generated
# code that produces — rather than failing outright on `#lang` as unknown `#`
# syntax. A plain (non-`#lang`) script is unaffected either way, since
# forms_for falls through to the ordinary Reader for it.
def dump_bytecode(path : String, strict : Bool = false) : Nil
  interp = Creme::Interpreter.new(library_search_path: ["./modules"], auto_import_base: !strict)
  src = File.read(path)
  # Push the script's own directory, matching Creme.run_file, so a relative
  # (include "...") inside it resolves against where the script lives, not
  # the process's CWD.
  interp.push_load_dir(File.dirname(File.expand_path(path)))
  begin
    forms = Creme.forms_for(interp, src, path)
    forms.each_with_index do |form, i|
      node = interp.analyze(form, interp.global)
      chunk = Creme::BytecodeCompiler.compile_program([node])
      puts "; ---- top-level form #{i} ----" if forms.size > 1
      Creme::Disassembler.disassemble(chunk, "form #{i}")
      Creme::VM.new(interp, interp.global).run(chunk)
    end
  ensure
    interp.pop_load_dir
  end
end

# Disassembles an ALREADY-COMPILED ICE1 file (e.g. one written by
# `--emit-icecreme`, or by the self-hosted (creme compiler compiler)'s own
# compile-source-to-bytes/chunk->bytes) — unlike dump_bytecode above,
# which always compiles SOURCE fresh, this reads raw bytes straight off
# disk via the exact same ChunkDeserializer both `load-chunk-bytes` and
# icecreme's own loader.c round-trip through, so what it prints is exactly
# what would actually run, not a fresh recompile that might legitimately
# differ (e.g. a different fusable-primitive set already imported at the
# time the file was originally compiled).
#
# ChunkDeserializer resolves each TAG_BUILTIN const by NAME against a
# live env (chunk_deserializer.cr's own doc comment) — the file itself
# doesn't record which libraries were imported when it was compiled, so
# there's no way to know in general which builtins it references. Import
# a broad, "kitchen sink" set of standard + creme libraries up front
# (matching this project's own toolchain-loading convention elsewhere,
# e.g. compiler_spec.cr's load_toolchain) to cover the common case; a
# file whose original compile also had some OTHER creme library imported
# (sql/sxql/mux/...) can still raise "unknown builtin" here — a real,
# accepted limitation of disassembling a file with no record of its own
# original import list, not a bug.
KITCHEN_SINK_IMPORT = %((import (scheme base) (scheme write) (scheme cxr) (scheme complex)
                                 (scheme inexact) (scheme char) (scheme lazy) (scheme eval)
                                 (scheme time) (scheme process-context) (scheme file)
                                 (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
                                 (creme compiler reader) (creme compiler compiler)))

def disassemble_ice1(path : String) : Nil
  bytes = File.read(path).to_slice
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, KITCHEN_SINK_IMPORT)
  chunk = Creme::ChunkDeserializer.deserialize(bytes, interp.global)
  Creme::Disassembler.disassemble(chunk, File.basename(path))
end

# Handles `creme --disassemble <file.ice>` — split out of `main` purely to
# keep that method's own top-level dispatch simple.
def handle_disassemble(args : Array(String)) : Nil
  unless path = args[1]?
    STDERR.puts "Usage: creme --disassemble <file.ice>"
    exit 1
  end
  unless File.exists?(path)
    STDERR.puts "creme: #{path}: no such file"
    exit 1
  end
  begin
    disassemble_ice1(path)
  rescue ex : Creme::ChunkDeserializer::FormatError
    STDERR.puts "creme: #{path}: #{ex.message}"
    exit 1
  rescue ex : Creme::SchemeError
    STDERR.puts format_error(ex)
    exit 1
  rescue ex
    STDERR.puts "Internal error: #{ex.message}"
    exit 1
  end
end

# Compiles `path` (same auto-import-base convention as dump_bytecode above,
# so builtins fuse the same way a real run would) into a single Chunk and
# serializes it to `out_path` via IcecremeEmitter/ChunkSerializer (the same
# "ICE1" format the real Crystal VM already round-trips through) — for
# `creme --emit-icecreme`, feeding the standalone C11 prototype VM in icecreme/ (see
# icecreme/README.md for current opcode/value-model coverage). Pushes path's own
# directory first, same as Creme.run_file — bench/creme.scm's own
# `(include "workloads.scm")` resolves relative to wherever the script
# lives, not the process's CWD, so this must match run_file's convention
# rather than dump_bytecode's (which doesn't push one at all) for `creme
# --emit-icecreme bench/creme.scm ...` to work when invoked from the repo root.
def emit_icecreme(path : String, out_path : String) : Nil
  interp = Creme::Interpreter.new(library_search_path: ["./modules"], auto_import_base: true)
  interp.push_load_dir(File.dirname(File.expand_path(path)))
  begin
    src = File.read(path)
    forms = Creme.forms_for(interp, src, path)
    bytes = Creme::IcecremeEmitter.emit(interp, forms, interp.global)
    File.write(out_path, bytes)
  ensure
    interp.pop_load_dir
  end
end

# Handles `creme --emit-icecreme <file.scm> <out.ice>` — split out of `main`
# purely to keep that method's own top-level dispatch simple.
def handle_emit_icecreme(args : Array(String)) : Nil
  unless args[1]? && args[2]?
    STDERR.puts "Usage: creme --emit-icecreme <file.scm> <out.ice>"
    exit 1
  end
  begin
    path = args[1]
    out_path = args[2]
    emit_icecreme(path, out_path)
  rescue ex : Creme::SchemeError
    STDERR.puts format_error(ex)
    exit 1
  rescue ex
    STDERR.puts "Internal error: #{ex.message}"
    exit 1
  end
end

# Shared by `creme --icecreme <file.scm>` and `creme --profile --icecreme <file.scm>`:
# emits <file.scm> to a throwaway .ice file, runs it via icecreme/icecreme (with
# `icecreme_args` — e.g. ["--profile"], or [] for a plain run — passed ahead of
# the compiled file's own path), then cleans up the intermediate file.
# Assumes the repo-root-relative "icecreme/icecreme" path, same convention
# bench/bench.scm's own run-variant calls rely on for locating it.
def run_via_icecreme(path : String, icecreme_args : Array(String)) : Nil
  icecreme_bin = "icecreme/icecreme"
  unless File.exists?(icecreme_bin)
    STDERR.puts "creme: #{icecreme_bin} not found — build it first (`make -C icecreme`)"
    exit 1
  end

  tmp_path = File.tempname("creme-icecreme", ".ice")
  exit_code = 1
  begin
    emit_icecreme(path, tmp_path)
    status = Process.run(icecreme_bin, icecreme_args + [tmp_path],
      output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
    exit_code = status.exit_code
  rescue ex : Creme::SchemeError
    STDERR.puts format_error(ex)
  rescue ex
    STDERR.puts "Internal error: #{ex.message}"
  ensure
    File.delete(tmp_path) if File.exists?(tmp_path)
  end
  exit(exit_code)
end

# Handles `creme --icecreme <file.scm>` — combines --emit-icecreme (to a throwaway
# file) with a plain `icecreme/icecreme <that file>` run, so running a script under the
# C prototype VM doesn't need its own separate compile-then-run step. Split
# out of `main` purely to keep that method's own top-level dispatch simple.
def handle_icecreme(args : Array(String)) : Nil
  unless path = args[1]?
    STDERR.puts "Usage: creme --icecreme <file.scm>"
    exit 1
  end
  run_via_icecreme(path, [] of String)
end

# Handles `creme --profile --icecreme <file.scm>` — same as --icecreme above, but runs
# icecreme/icecreme with --profile (see icecreme/README.md's "Profiling" section). Split out
# of `main` purely to keep that method's own top-level dispatch simple.
def handle_profile_icecreme(args : Array(String)) : Nil
  unless path = args[2]?
    STDERR.puts "Usage: creme --profile --icecreme <file.scm>"
    exit 1
  end
  run_via_icecreme(path, ["--profile"])
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
  rescue ex : Creme::SchemeExit
    exit(ex.code)
  rescue ex : Creme::SchemeError
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
# script as the profiled thunk — `load` (src/creme/modules/scheme/
# load.cr) resolves/pushes the target's own directory exactly like
# Creme.run_file does, and respects a `#lang` header exactly the same
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
    interp = Creme::Interpreter.new(library_search_path: ["./modules"], auto_import_base: false)
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
    Creme.run_source(interp, wrapper, source_name: path)
  rescue ex : Creme::SchemeExit
    exit(ex.code)
  rescue ex : Creme::SchemeError
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
  interp = Creme::Interpreter.new(library_search_path: ["./modules"], auto_import_base: false)
  src = STDIN.gets_to_end
  Creme::BytecodeCompiler.run_program(interp, Creme::Reader.read_all(src, "<stdin>"), interp.global)
rescue ex : Creme::SchemeExit
  exit(ex.code)
rescue ex : Creme::SchemeError
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
  Creme.run_file(Creme::Interpreter.new(library_search_path: ["./modules"], auto_import_base: false), path)
rescue ex : Creme::SchemeExit
  exit(ex.code)
rescue ex : Creme::SchemeError
  STDERR.puts format_error(ex)
  exit 1
rescue ex
  STDERR.puts "Internal error: #{ex.message}"
  exit 1
end

# The (import ...) form that loads the self-hosted compiler's own
# toolchain -- same import list compiler_spec.cr's own load_toolchain
# helper uses, kept in sync with it by hand since there's no shared
# constant between a _spec.cr file and src/main.cr.
SELF_HOSTED_TOOLCHAIN_IMPORT = %((import (scheme lazy) (scheme eval) (scheme cxr) (creme peg) (creme regex) (creme bytecode) (creme bootstrap) (creme compiler reader) (creme compiler compiler)))

# Pre-seeds ensure-library-loaded!'s own "already loaded" tracking
# (compiler.sld's own mark-self-hosted-library-loaded!) for every
# file-based library SELF_HOSTED_TOOLCHAIN_IMPORT above already loaded
# NATIVELY (this whole toolchain import runs through Crystal's own real
# import machinery, which the self-hosted compiler's own loader has no
# way to know about) -- mirrors icecreme/compiler-run.scm's own identical
# pre-seeding, needed for the identical reason (that file's own header
# comment): once compiler.sld's own file-reading (file-read, via (creme
# file)) genuinely works under self-hosted too (previously silently
# broken there, so ensure-library-loaded! always fell through to a
# native-introspection fallback instead of ever actually re-reading a
# library's own .sld source), a script that ALSO imports one of these
# same libraries -- exactly what every spec/creme/*.scm file does,
# transitively -- would otherwise have that library's source re-read
# and re-run a SECOND time here too, re-executing (creme bytecode)'s own
# (define-record-type <chunk> ...) and re-creating a nominally NEW,
# disjoint record type that corrupts any chunk/fcomp object this SAME
# reentrant self-hosted-compiler invocation is already holding from the
# original, natively-loaded generation. (scheme lazy)/(scheme eval)/
# (scheme cxr)/(creme bootstrap)/(creme regex) need no entry -- none has
# a .sld file on disk, so the loader already no-ops for them regardless.
SELF_HOSTED_TOOLCHAIN_MARK_LOADED = %(
  (mark-self-hosted-library-loaded! '(creme peg))
  (mark-self-hosted-library-loaded! '(creme bytecode))
  (mark-self-hosted-library-loaded! '(creme compiler reader))
  (mark-self-hosted-library-loaded! '(creme compiler compiler)))

# Runs `path` through the self-hosted (creme compiler compiler) instead
# of the native Crystal BytecodeCompiler run_script/Creme.run_file uses —
# for `creme --self-hosted`, an explicit opt-in rather than the
# interpreter's default execution path (see that flag's own usage text
# for why: real performance cost, since compilation itself now runs as
# interpreted Scheme on the VM, and this compiler's own surface area
# hasn't been exercised across every corner of the codebase the way the
# native compiler has). Mirrors run_script's own auto_import_base: false
# (a script must explicitly import what it uses, per R7RS) and load-dir
# push/pop (so a relative (include ...) inside the script resolves
# against where the script lives, matching Creme.run_file's own
# convention) -- the only difference from run_script is compiling via
# compile-source-to-bytes + load-chunk-bytes instead of BytecodeCompiler.
def run_self_hosted(path : String) : Nil
  interp = Creme::Interpreter.new(library_search_path: ["./modules"], auto_import_base: false)
  Creme.run_source(interp, SELF_HOSTED_TOOLCHAIN_IMPORT)
  Creme.run_source(interp, SELF_HOSTED_TOOLCHAIN_MARK_LOADED)
  interp.push_load_dir(File.dirname(File.expand_path(path)))
  begin
    interp.global.define("self-hosted-script-source", Creme::SchemeStr.new(File.read(path)))
    # Passed through as compile-source-to-bytes' own optional 2nd (file
    # path) argument -- lets a genuinely nested `(include ...)` (inside a
    # let/lambda body, not just this file's own top level) resolve a
    # relative path against THIS file's own directory (compiler.sld's own
    # current-compiling-file/expand-include-form). A plain global (not
    # string-interpolated into the source below) so there's no escaping
    # to worry about.
    interp.global.define("self-hosted-script-path", Creme::SchemeStr.new(path))
    # A marker only this path defines -- (creme introspection)'s `runtime`
    # builtin checks whether it's bound in interp.global to report
    # compiler = "self-hosted" vs "native" (see introspection.cr's
    # `runtime` method). Its value is never inspected, only its presence.
    interp.global.define("__creme_self_hosted__", Creme::TRUE)
    Creme.run_source(interp, "(load-chunk-bytes (compile-source-to-bytes self-hosted-script-source self-hosted-script-path))", source_name: path)
  ensure
    interp.pop_load_dir
  end
rescue ex : Creme::SchemeExit
  exit(ex.code)
rescue ex : Creme::SchemeError
  STDERR.puts format_error(ex)
  exit 1
rescue ex
  STDERR.puts "Internal error: #{ex.message}"
  exit 1
end

# Interactive `creme --self-hosted` with no file argument: the same
# shared (creme repl) library every other REPL entry point now delegates
# to, run against a self-hosted-toolchain-loaded interpreter instead of a
# script's contents -- this "falls out" of unifying the REPLs, since the
# self-hosted toolchain load is identical to run_self_hosted's, just
# followed by (run-repl) instead of compiling+running a file's source.
def run_self_hosted_repl : Nil
  interp = Creme::Interpreter.new(library_search_path: ["./modules"], auto_import_base: false)
  Creme.run_source(interp, SELF_HOSTED_TOOLCHAIN_IMPORT)
  Creme.run_source(interp, SELF_HOSTED_TOOLCHAIN_MARK_LOADED)
  interp.global.define("__creme_self_hosted__", Creme::TRUE)
  Creme.run_source(interp, "(import (scheme process-context)) (import (creme repl)) (run-repl)")
rescue ex : Creme::SchemeExit
  exit(ex.code)
rescue ex : Creme::SchemeError
  STDERR.puts format_error(ex)
  exit 1
rescue ex
  STDERR.puts "Internal error: #{ex.message}"
  exit 1
end

# Handles `creme --self-hosted <file.scm>` — split out of `main` purely to
# keep that method's own top-level dispatch simple. With no file argument
# AND a real tty on stdin, starts the shared interactive REPL against the
# self-hosted toolchain instead of erroring out (new capability that falls
# out of unifying the REPLs). A piped/non-tty invocation without a file
# argument keeps the existing required-path behavior unchanged (matches
# spec/main_spec.cr's "--self-hosted requires a file argument" — with no
# real terminal and no file to run, there is nothing useful to do).
def handle_self_hosted(args : Array(String)) : Nil
  unless path = args[1]?
    if STDIN.tty?
      run_self_hosted_repl
      return
    end
    STDERR.puts "Usage: creme --self-hosted <file.scm>"
    exit 1
  end
  run_self_hosted(path)
end

# ameba:disable Metrics/CyclomaticComplexity
def main : Nil
  # Crystal's own runtime already ran GC.init (and honored an explicit
  # GC_INITIAL_HEAP_SIZE env var, if set) before this method was ever
  # called -- so, same as icecreme/main.c, only step in with our own default
  # when the caller didn't set one. Benchmarked (doc/optimization-crystal.md's
  # own GC env-var section) across the same 9 competition/bench.scm
  # workloads, median of 11 runs each: unset (libgc's own default) 0.342s
  # total vs. 256M 0.265s (-22.6%), with 1G measuring the same as 256M (no
  # further win). GC_ENABLE_INCREMENTAL was also tested and made things
  # worse (+17%) -- not adopted, see that doc's dead-end note.
  if !ENV["GC_INITIAL_HEAP_SIZE"]?
    default_heap = LibC::SizeT.new(256 * 1024 * 1024)
    heap_size = LibGC.get_heap_size
    LibGC.expand_hp(default_heap - heap_size) if heap_size < default_heap
  end

  args = ARGV
  if args.empty?
    if STDIN.tty?
      # Interactive REPL: batteries-included, matching this project's
      # established ergonomics — (scheme base)/(scheme write) are
      # auto-imported so there's no friction typing expressions live.
      interp = Creme::Interpreter.new(library_search_path: ["./modules"])
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
  when "--disassemble"
    handle_disassemble(args)
  when "--emit-icecreme"
    handle_emit_icecreme(args)
  when "--icecreme"
    handle_icecreme(args)
  when "--self-hosted"
    handle_self_hosted(args)
  when "--profile"
    if args[1]? == "--icecreme"
      handle_profile_icecreme(args)
    else
      handle_profile(args)
    end
  else
    run_script(args[0])
  end
end

main
