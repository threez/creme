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
def dump_bytecode(path : String, strict : Bool = false) : Nil
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"], auto_import_base: !strict)
  src = File.read(path)
  forms = Scheme::Reader.read_all(src, path)
  forms.each_with_index do |form, i|
    node = interp.analyze(form, interp.global)
    chunk = Scheme::BytecodeCompiler.compile_program([node])
    puts "; ---- top-level form #{i} ----" if forms.size > 1
    Scheme::Disassembler.disassemble(chunk, "form #{i}")
    Scheme::VM.new(interp, interp.global).run(chunk)
  end
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
  when "--help", "-h"
    usage
  when "--dump-bytecode", "-S"
    handle_dump_bytecode(args)
  else
    begin
      # A script file must explicitly import what it uses, per R7RS —
      # see the auto_import_base doc comment on Interpreter#initialize.
      Scheme.run_file(Scheme::Interpreter.new(library_search_path: ["./modules"], auto_import_base: false), args[0])
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
end

main
