# ===========================================================================
# Runner: run_source, run_file
# ===========================================================================
#
# Pure library entry points — no STDOUT/STDERR/exit here. Callers (e.g.
# src/main.cr) own presentation and process lifecycle.

module Creme
  # `#lang <library-name> <extra-datum> ...` as the literal first line of a
  # file (e.g. `#lang (creme syntax mex)`, or `#lang (creme syntax scss)
  # (export css)`) selects that library's own Scheme-level parser for the
  # rest of the file, instead of the ordinary Reader — see
  # modules/creme/syntax/mex.sld for a concrete example and `(creme
  # reader)` (src/creme/modules/creme/reader.cr) for the token-stream
  # hook it's built on. `#lang` dialects live under `(creme syntax ...)`
  # (modules/creme/syntax/{mex,scss,slim}.sld) purely as a naming/
  # organizational convention — grouping "libraries whose whole point is
  # to be named on a #lang line" apart from ordinary `(creme ...)`
  # libraries; nothing here treats that prefix specially, any library
  # name works. Checked wherever `forms_for` is used — currently
  # run_source/run_file (a whole script run), `load` (src/creme/
  # modules/scheme/load.cr), and `--dump-bytecode` (src/main.cr's
  # dump_bytecode) — not the REPL or `eval`.
  #
  # Contract: the named library must export a procedure `read-program`
  # with signature `(read-program src source-name header-args) ->
  # list-of-forms`, where `src` is everything in the file after the
  # `#lang` line (a string), `source-name` is the file's own name/path
  # (for error positions, also a string), and `header-args` is a proper
  # Scheme list of whatever additional data followed the library name on
  # the header line (empty if none). The return value must be a proper
  # Scheme list of ordinary forms; each one is then analyzed/compiled/run
  # exactly like a form the plain Reader would have produced — nothing
  # downstream of this point knows a dialect was involved at all.
  #
  # header-args is how a dialect distinguishes "run as a whole program"
  # from "loaded as a reusable definition" without the Crystal runner
  # needing to know anything dialect-specific: `(creme syntax mex)`
  # ignores it (a whole mex program is always a list of forms to run for
  # effect, run standalone or loaded, identically). `(creme syntax
  # scss)`/`(creme syntax slim)` check it, using the same tagged-form
  # convention `import`'s own grammar already establishes: no `(export
  # name)` among header-args (`./bin/creme style.scss` run standalone)
  # -> compile and print to stdout, for a quick demo; `(export name)`
  # present (e.g. `#lang (creme syntax scss) (export css)`, typically
  # reached via `(load "style.scss")`) -> return `(define css <compiled
  # value>)` instead, so the loaded file behaves like an ordinary
  # reusable definition — see modules/creme/syntax/scss.sld and
  # modules/creme/syntax/slim.sld for exactly what each binds, and for
  # `(creme syntax slim)`'s own additional `(params ...)`/`(import
  # lib-set ...)` header-args (the generated procedure's parameter list,
  # and libraries its own `=` expressions need beyond the always-
  # available (scheme base)).
  #
  # How `read-program` gets from src to forms is entirely up to the
  # library: see `(creme syntax mex)` for a token-stream-transform
  # implementation built on `(creme reader)`, or hand-write a from-
  # characters parser using `(scheme base)`'s port primitives
  # (open-input-string/read-char/peek-char/...) for a dialect that needs
  # to diverge from Scheme's own lexical grammar entirely (see `(creme
  # syntax scss)`/`(creme syntax slim)`, and the shared scanning helpers
  # they both use, `(creme scanner)` — an ordinary, ungrouped library
  # since it's generically useful text-parsing code, not specific to
  # writing a `#lang` dialect).
  LANG_HEADER_PREFIX = "#lang "

  # Returns every datum on `src`'s first line after `#lang ` (e.g.
  # `["(creme syntax scss)", "(export css)"]`'s parsed equivalent) if
  # it's a `#lang ...` header, or nil otherwise — no further validation of
  # the first datum's shape happens here; `import_into` raises its own
  # clear error for anything that isn't a legal import-set.
  def self.lang_header_data(src : String) : Array(SchemeValue)?
    return nil unless src.starts_with?(LANG_HEADER_PREFIX)
    line_end = src.index('\n') || src.size
    line_rest = src[LANG_HEADER_PREFIX.size...line_end]
    Reader.read_all(line_rest, "<#lang>")
  end

  # Imports the #lang line's named library into a throwaway, parentless Env
  # (mirroring how a library body's own Env has no parent — see
  # import.cr's build_library), looks up its `read-program` export, and
  # calls it with the remainder of the file's source text plus the header
  # line's remaining data (see the contract above).
  private def self.read_via_lang_dialect(interp : Interpreter, header_data : Array(SchemeValue), src : String, source_name : String) : Array(SchemeValue)
    lang_form = header_data[0]
    header_args = Creme.a_to_list(header_data[1..])
    body_start = (src.index('\n') || src.size) + 1
    body = body_start < src.size ? src[body_start..] : ""
    dialect_env = Env.new
    interp.import_into(dialect_env, lang_form)
    reader_proc = dialect_env.get?("read-program") ||
                  raise SchemeRuntimeError.new("#lang #{lang_form.write_string}: library does not export read-program")
    result = interp.apply(reader_proc, [SchemeStr.new(body), SchemeStr.new(source_name), header_args] of SchemeValue)
    Creme.list_to_a(result)
  end

  # The forms `src` (from a file named `source_name`, for error positions)
  # parses to — via the `#lang` dialect its first line names, or the
  # ordinary Reader otherwise. Shared by run_source, `load` (see
  # src/creme/modules/scheme/load.cr), and `--dump-bytecode` (src/main.cr) —
  # each recognizes `#lang` the same way; only the REPL and `eval` don't.
  def self.forms_for(interp : Interpreter, src : String, source_name : String) : Array(SchemeValue)
    if header_data = lang_header_data(src)
      read_via_lang_dialect(interp, header_data, src, source_name)
    else
      Reader.read_all(src, source_name)
    end
  end

  # bindings/parent let a host inject data and isolate one call from the
  # next while reusing a single warm Interpreter:
  #   - neither given: evals against interp.global, unchanged from before.
  #   - bindings given: evals against a fresh child of (parent || interp.global),
  #     seeded with bindings and discarded after the call — nothing leaks
  #     into interp.global or a later call.
  #   - parent given alone: evals directly against it (host controls isolation).
  #   - both given: fresh child of parent, seeded with bindings — lets a host
  #     register expensive callbacks once on a reusable parent env, then
  #     reuse it as the chain root for many cheap, isolated calls.
  def self.run_source(interp : Interpreter, src : String, bindings : Hash(String, SchemeValue)? = nil, parent : Env? = nil, source_name : String = "<repl>") : SchemeValue
    root = parent || interp.global
    env : Env = root
    if bindings
      env = Env.new(root)
      bindings.each { |k, v| env.define(k, v) }
    end
    # BytecodeCompiler.run_program analyzes, compiles, and runs one form at a
    # time against `env` (mirroring this exact per-form loop) rather than
    # analyzing the whole program up front — required for a top-level
    # define-syntax/import to affect a LATER form's analysis.
    BytecodeCompiler.run_program(interp, forms_for(interp, src, source_name), env)
  end

  def self.run_file(interp : Interpreter, path : String, bindings : Hash(String, SchemeValue)? = nil, parent : Env? = nil) : SchemeValue
    raise SchemeRuntimeError.new("file not found: #{path}") unless File.exists?(path)
    # Push the script's own directory so a relative (require "...") inside it
    # resolves against where the script lives, not the process's CWD.
    interp.push_load_dir(File.dirname(File.expand_path(path)))
    begin
      run_source(interp, File.read(path), bindings, parent, source_name: path)
    ensure
      interp.pop_load_dir
    end
  end
end
