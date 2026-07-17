# ===========================================================================
# (scheme base) / (scheme write): the core builtins installed into @base_env
# ===========================================================================
#
# install_builtins is a thin dispatcher over the section installers that
# live alongside this file under modules/scheme/base/ (arithmetic.cr,
# pairs_lists.cr, vectors.cr, higher_order.cr, predicates.cr, strings.cr,
# io.cr, misc.cr — plus bytevectors.cr/exceptions.cr/write.cr, installed
# separately from Interpreter#initialize). Each section installer returns
# its own register_module names; (scheme base)'s export list is the union
# of all of those (the builtins that self-declare via their owning module)
# plus SCHEME_BASE_NONFN (below), and (scheme write)'s is install_write's
# names — so there is no hand-maintained builtin allowlist that could drift
# out of sync with the modules. Both libraries' Env *is* @base_env itself
# (see Interpreter#initialize), not @global. @global (the top-level
# program's own root Env) only sees these names if
# Interpreter.new(auto_import_base: true) (the default) imports them via
# AUTO_IMPORTED_LIBRARIES, or the program itself (import (scheme base)) /
# (import (scheme write)). auto_import_base: true preserves this project's
# established "batteries included" ergonomics for the REPL;
# auto_import_base: false matches strict R7RS (every program must
# explicitly import (scheme base)) and is used for file/stdin script
# execution — see src/main.cr. Either way, every name is correctly
# attributed to a real library (R7RS-standard or (list ...) extension) —
# there is no ungoverned always-on blob of bindings.
#
# SCHEME_BASE_NONFN holds the only base exports that AREN'T annotated
# methods (syntactic keywords + the current-*-port parameter objects) — the
# irreducible remainder that can't be derived from a register_module return.
#
# Cross-cutting argument-coercion helpers (int_arg, vector_arg, ...) used
# by several section files here, by base/bytevectors.cr, and by the VM's
# exec_prim now live in Scheme::BuiltinHelpers (builtin_helpers.cr).

module Scheme
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

    # (scheme base)'s only exports that are NOT annotated builtin methods, so
    # they can't be derived from a register_module return: the syntactic
    # keywords base chooses to export (a deliberate subset of
    # SPECIAL_FORM_NAMES — note it omits defmacro/define-library/import/λ/
    # delay/letrec*/include/include-ci) plus the three current-*-port
    # parameter objects (defined via env.define in base/io.cr). Every other
    # base export is self-declared by whichever section module owns it.
    SCHEME_BASE_NONFN = %w[
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
    AUTO_IMPORTED_LIBRARIES = [["scheme", "base"], ["scheme", "write"]]

    # base_names/write_names are the section modules' own register_module
    # return values (collected in Interpreter#initialize); base's export set
    # is those plus SCHEME_BASE_NONFN (the non-method syntactic/parameter
    # exports). Both libraries' Env *is* @base_env itself.
    private def install_base_and_write_libraries(base_names : Array(String), write_names : Array(String)) : Nil
      base_exports = (base_names + SCHEME_BASE_NONFN).to_h { |name| {name, name} }
      register_library(["scheme", "base"], @base_env, base_exports)

      write_exports = write_names.to_h { |name| {name, name} }
      register_library(["scheme", "write"], @base_env, write_exports)
    end
  end
end
