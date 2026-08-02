# ===========================================================================
# (builtin base) / (builtin write): the core builtins installed into @base_env
# (scheme base) / (scheme write): the same, plus a Scheme-defined layer
# ===========================================================================
#
# install_builtins is a thin dispatcher over the section installers that
# live alongside this file under modules/scheme/base/ (arithmetic.cr,
# pairs_lists.cr, vectors.cr, higher_order.cr, predicates.cr, strings.cr,
# io.cr, misc.cr — plus bytevectors.cr/exceptions.cr/write.cr, installed
# separately from Interpreter#initialize). Each section installer returns
# its own register_module names; (builtin base)'s export list is the union
# of all of those (the builtins that self-declare via their owning module)
# plus BUILTIN_BASE_NONFN (below), and (builtin write)'s is install_write's
# names — so there is no hand-maintained builtin allowlist that could drift
# out of sync with the modules. Both libraries' Env *is* @base_env itself
# (see Interpreter#initialize), not @global.
#
# (scheme base) and (scheme write) are ordinary libraries built through the
# normal define-library machinery (build_library in eval/import.cr) — each
# just (import (builtin base))/(import (builtin write)), re-exports
# everything from it, and (for (scheme base)) layers a handful of
# Scheme-defined procedures on top (see install_scheme_base_and_write_libraries
# below). This is the extension point for moving a base procedure from
# native Crystal to Scheme source: delete its @[Creme::SchemeFn] method and
# add its Scheme definition (+ name in the export list) there instead.
#
# @global (the top-level program's own root Env) only sees (scheme
# base)/(scheme write)'s names if Interpreter.new(auto_import_base: true)
# (the default) imports them via AUTO_IMPORTED_LIBRARIES, or the program
# itself (import (scheme base)) / (import (scheme write)).
# auto_import_base: true preserves this project's established "batteries
# included" ergonomics for the REPL; auto_import_base: false matches strict
# R7RS (every program must explicitly import (scheme base)) and is used for
# file/stdin script execution — see src/main.cr. (builtin base)/(builtin
# write) are never auto-imported — only reachable via an explicit (import
# (builtin base)) — matching ordinary R7RS import ergonomics. Either way,
# every name is correctly attributed to a real library (R7RS-standard or
# (list ...) extension) — there is no ungoverned always-on blob of bindings.
#
# BUILTIN_BASE_NONFN holds the only (builtin base) exports that AREN'T
# annotated methods (syntactic keywords + the current-*-port parameter
# objects) — the irreducible remainder that can't be derived from a
# register_module return, and that can never move to the Scheme-defined
# layer (you can't define `if`/`lambda` in Scheme in this interpreter).
#
# Cross-cutting argument-coercion helpers (int_arg, vector_arg, ...) used
# by several section files here, by base/bytevectors.cr, and by the VM's
# exec_prim now live in Creme::BuiltinHelpers (builtin_helpers.cr).

module Creme
  class Interpreter
    # Returns the concatenation of every section installer's own
    # register_module return value — the full set of (scheme base) builtin
    # names, self-declared by the modules that own them (no hand-maintained
    # allowlist). install_bytevectors/install_exceptions are folded in by the
    # caller (Interpreter#initialize) since they're installed separately.
    private def install_builtins(env : Env) : Array(String)
      names = [] of String
      names.concat(install_arithmetic(env))
      names.concat(install_pairs_and_lists(env))
      names.concat(install_vectors(env))
      names.concat(install_higher_order(env))
      names.concat(install_predicates(env))
      names.concat(install_strings(env))
      names.concat(install_io(env))
      names.concat(install_misc(env))
      names
    end

    # (builtin base)'s only exports that are NOT annotated builtin methods,
    # so they can't be derived from a register_module return: the syntactic
    # keywords base chooses to export (a deliberate subset of
    # SPECIAL_FORM_NAMES — note it omits defmacro/define-library/import/λ/
    # delay/letrec*/include/include-ci) plus the three current-*-port
    # parameter objects (defined via env.define in base/io.cr). Every other
    # base export is self-declared by whichever section module owns it.
    BUILTIN_BASE_NONFN = %w[
      and begin case case-lambda cond cond-expand define define-record-type
      define-syntax define-values do guard if lambda let let* let*-values
      let-syntax let-values letrec letrec-syntax or parameterize quasiquote
      quote set! unless unquote unquote-splicing when
      current-input-port current-output-port current-error-port
    ]

    # Libraries copied into @global at construction when
    # Interpreter.new(auto_import_base: true) (the default — see
    # Interpreter#initialize). Everything else stays import-only always,
    # matching real R7RS library scoping — including (creme extra) (this
    # project's own non-R7RS conveniences). Being a file-based .sld library
    # (modules/creme/extra.sld), it isn't eligible for auto-import at
    # construction (that would require reading a file off library_search_path
    # before any script runs, which an embedder who never sets
    # library_search_path shouldn't be forced into) — it must be explicitly
    # (import (creme extra))ed like any other file-based library, same as
    # (creme sxql).
    AUTO_IMPORTED_LIBRARIES = [["creme", "builtin", "base"], ["creme", "builtin", "write"]]

    # base_names/write_names are the section modules' own register_module
    # return values (collected in Interpreter#initialize); (builtin base)'s
    # export set is those plus BUILTIN_BASE_NONFN (the non-method
    # syntactic/parameter exports). Both libraries' Env *is* @base_env
    # itself.
    private def install_builtin_libraries(base_names : Array(String), write_names : Array(String)) : Nil
      base_exports = (base_names + BUILTIN_BASE_NONFN).to_h { |name| {name, name} }
      register_library(["creme", "builtin", "base"], @base_env, base_exports)

      write_exports = write_names.to_h { |name| {name, name} }
      register_library(["creme", "builtin", "write"], @base_env, write_exports)
    end

    # (scheme base)'s own Scheme-defined layer, on top of (builtin base) —
    # the extension point described in this file's header comment. Add a
    # Scheme-implemented (scheme base) procedure here: write its `define`
    # in this source and add its name to SCHEME_BASE_ADDITIONS_NAMES.
    # list-copy/list-set! are ported here (from
    # modules/scheme/base/pairs_lists.cr) as the first two such procedures —
    # both are trivial in terms of other (builtin base) primitives and
    # aren't referenced anywhere else in this codebase. Note list-copy here
    # is more R7RS-conformant than the native version it replaces: it copies
    # the spine of an improper (dotted) list and shares the final non-pair
    # cdr, where the old native version raised on any dotted list.
    SCHEME_BASE_ADDITIONS_SRC = <<-SCHEME
      (define (list-copy lst)
        (if (pair? lst) (cons (car lst) (list-copy (cdr lst))) lst))
      (define (list-set! lst k obj)
        (set-car! (list-tail lst k) obj))
      SCHEME

    SCHEME_BASE_ADDITIONS_NAMES = %w[list-copy list-set!]

    # Builds (scheme base)/(scheme write): a fresh Env per library, populated
    # by directly copying (builtin base)/(builtin write)'s own bindings in
    # (the same "read @libraries, then SchemeLibrary.import_bindings"
    # idiom (scheme r5rs) already uses to import (scheme base) — see
    # modules/scheme/r5rs.cr) plus, for (scheme base), evaluating the
    # Scheme-defined additions against that Env. This deliberately bypasses
    # the ordinary import/resolve_library path (Interpreter#import_into) —
    # that path enforces allowed_libraries (see Interpreter.sandboxed),
    # which must never gate the interpreter's own internal bootstrap wiring,
    # only a guest program's own (import ...) forms.
    private def install_scheme_base_and_write_libraries : Nil
      builtin_base = @libraries[["creme", "builtin", "base"]]
      base_env = Env.new
      SchemeLibrary.import_bindings(base_env, builtin_base.exports.map { |external, internal| {external, builtin_base, internal} })
      BytecodeCompiler.run_program(self, Reader.read_all(SCHEME_BASE_ADDITIONS_SRC, "<scheme base>"), base_env)
      base_exports = (builtin_base.exports.keys + SCHEME_BASE_ADDITIONS_NAMES).to_h { |name| {name, name} }
      register_library(["creme", "builtin", "base"], base_env, base_exports)

      builtin_write = @libraries[["creme", "builtin", "write"]]
      write_env = Env.new
      SchemeLibrary.import_bindings(write_env, builtin_write.exports.map { |external, internal| {external, builtin_write, internal} })
      write_exports = builtin_write.exports.keys.to_h { |name| {name, name} }
      register_library(["creme", "builtin", "write"], write_env, write_exports)
    end
  end
end
