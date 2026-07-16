# ===========================================================================
# (scheme base) / (scheme write): the core builtins installed into @base_env
# ===========================================================================
#
# install_builtins is a thin dispatcher over the section installers that
# live alongside this file under modules/scheme/base/ (arithmetic.cr,
# pairs_lists.cr, vectors.cr, higher_order.cr, predicates.cr, strings.cr,
# io.cr, misc.cr — plus bytevectors.cr/exceptions.cr, installed separately
# from Interpreter#initialize as install_bytevectors/install_exceptions).
# SCHEME_BASE_EXPORTS/SCHEME_WRITE_EXPORTS (below) are the export-name
# allowlists filtering what all of those (plus install_special_forms)
# define into the real (scheme base)/(scheme write) libraries — both
# libraries' Env *is* @base_env itself (see Interpreter#initialize), not
# @global. @global (the top-level program's own root Env) only sees these
# names if Interpreter.new(auto_import_base: true) (the default) imports
# them via AUTO_IMPORTED_LIBRARIES, or the program itself (import (scheme
# base)) / (import (scheme write)). auto_import_base: true preserves this
# project's established "batteries included" ergonomics for the REPL;
# auto_import_base: false matches strict R7RS (every program must
# explicitly import (scheme base)) and is used for file/stdin script
# execution — see src/main.cr. Either way, every name is correctly
# attributed to a real library (R7RS-standard or (list ...) extension) —
# there is no ungoverned always-on blob of bindings.
#
# SCHEME_BASE_EXPORTS is a hand-maintained allowlist (not "everything
# currently in @base_env") so bindings added to @base_env elsewhere can't
# silently widen (scheme base)'s export surface.
#
# Cross-cutting argument-coercion helpers (int_arg, vector_arg, ...) used
# by several section files here, by base/bytevectors.cr, and by the VM's
# exec_prim now live in Scheme::BuiltinHelpers (builtin_helpers.cr).

module Scheme
  class Interpreter
    private def install_builtins(env : Env) : Nil
      install_arithmetic(env)
      install_pairs_and_lists(env)
      install_vectors(env)
      install_higher_order(env)
      install_predicates(env)
      install_strings(env)
      install_io(env)
      install_misc(env)
    end

    SCHEME_BASE_EXPORTS = %w[
      * + - / < <= = > >=
      abs and append apply assoc assq assv
      begin binary-port? boolean=? boolean?
      bytevector bytevector-append bytevector-copy bytevector-copy! bytevector-length
      bytevector-u8-ref bytevector-u8-set! bytevector?
      caar cadr call-with-current-continuation call-with-port call-with-values call/cc car case case-lambda cdar cddr cdr
      ceiling char->integer char-ready? char<=? char<? char=? char>=? char>? char?
      close-input-port close-output-port close-port cond cond-expand cons
      current-error-port current-input-port current-output-port
      define define-record-type define-syntax define-values denominator do dynamic-wind
      eof-object eof-object? eq? equal? eqv?
      error error-object-irritants error-object-message error-object? even? exact
      exact-integer-sqrt exact-integer? exact? expt
      features file-error? floor floor-quotient floor-remainder floor/ flush-output-port for-each
      gcd get-output-bytevector get-output-string guard
      if inexact inexact? input-port-open? input-port? integer->char integer?
      lambda lcm length let let* let-syntax let-values let*-values letrec letrec-syntax
      list list->string list->vector list-copy list-ref list-set! list-tail list?
      make-bytevector make-list make-parameter make-string make-vector map max member memq memv min modulo
      negative? newline not null? number->string number? numerator
      odd? open-input-bytevector open-input-string open-output-bytevector open-output-string or output-port-open? output-port?
      pair? parameterize peek-char peek-u8 port? positive? procedure?
      quasiquote quote quotient
      raise raise-continuable rational? rationalize read-bytevector read-bytevector! read-char
      read-error? read-line read-string read-u8 real? remainder reverse round
      set! set-car! set-cdr! square syntax-error
      string string->list string->number string->symbol string->utf8 string->vector
      string-append string-copy string-copy! string-fill! string-for-each string-length
      string-map string-ref string-set! string<=? string<? string=? string>=? string>? string?
      substring symbol->string symbol=? symbol?
      textual-port? truncate truncate-quotient truncate-remainder truncate/ u8-ready? unless unquote unquote-splicing utf8->string
      values vector vector->list vector->string vector-append vector-copy vector-copy!
      vector-fill! vector-for-each vector-length vector-map vector-ref vector-set! vector?
      when with-exception-handler write-bytevector write-char write-string write-u8 zero?
    ]

    SCHEME_WRITE_EXPORTS = %w[write display write-simple write-shared]

    # Libraries copied into @global at construction when
    # Interpreter.new(auto_import_base: true) (the default — see
    # Interpreter#initialize). Everything else stays import-only always,
    # matching real R7RS library scoping — including (creme extra) (this
    # project's own non-R7RS conveniences), which moved to a file-based
    # .sld library (modules/creme/extra.sld) and so is no longer eligible
    # for auto-import at construction (that would require reading a file
    # off library_search_path before any script runs, which an embedder
    # who never sets library_search_path shouldn't be forced into) — it
    # must be explicitly (import (creme extra))ed like any other
    # file-based library, same as (creme sxql).
    AUTO_IMPORTED_LIBRARIES = [["scheme", "base"], ["scheme", "write"]]

    private def install_base_and_write_libraries : Nil
      base_exports = SCHEME_BASE_EXPORTS.to_h { |name| {name, name} }
      register_library(["scheme", "base"], @base_env, base_exports)

      write_exports = SCHEME_WRITE_EXPORTS.to_h { |name| {name, name} }
      register_library(["scheme", "write"], @base_env, write_exports)
    end
  end
end
