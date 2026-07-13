# ===========================================================================
# R7RS sub-libraries: char, inexact, cxr, lazy, read, eval, process-context,
# case-lambda, time
# ===========================================================================
#
# Each gets its own fresh (non-@base_env) Env, following (scheme base)'s
# pattern from base_library.cr but WITHOUT the auto-import special case —
# these must be explicitly (import ...)ed, matching R7RS (only base/write
# are ever auto-imported, and only when Interpreter.new(auto_import_base:
# true), a deliberate deviation documented in base_library.cr).
#
# (scheme time) is REBUILT here (not just wrapped) to match R7RS's actual
# contract: current-second/current-jiffy/jiffies-per-second. The existing
# rich epoch/format time API (current-time, time-year, time->string, ...)
# is untouched and becomes (creme time) in Stage 5 — a superset, not
# replaced.

module Scheme
  class Interpreter
    SCHEME_CHAR_EXPORTS = %w[
      char-alphabetic? char-ci<=? char-ci<? char-ci=? char-ci>=? char-ci>?
      char-downcase char-foldcase char-lower-case? char-numeric?
      char-upcase char-upper-case? char-whitespace? digit-value
      string-ci<=? string-ci<? string-ci=? string-ci>=? string-ci>?
      string-downcase string-foldcase string-upcase
    ]

    SCHEME_INEXACT_EXPORTS = %w[acos asin atan cos exp finite? infinite? log nan? sin sqrt tan]

    SCHEME_CXR_EXPORTS = %w[
      caaaar caaadr caaar caadar caaddr caadr cadaar cadadr cadar caddar
      cadddr caddr cdaaar cdaadr cdaar cdadar cdaddr cdadr cddaar cddadr
      cddar cdddar cddddr cdddr
    ]

    SCHEME_LAZY_EXPORTS = %w[delay delay-force force make-promise promise?]

    SCHEME_READ_EXPORTS = %w[read]

    SCHEME_EVAL_EXPORTS = %w[environment eval]

    SCHEME_REPL_EXPORTS = %w[interaction-environment]

    SCHEME_R5RS_EXPORTS = SCHEME_BASE_EXPORTS + %w[null-environment scheme-report-environment]

    SCHEME_FILE_EXPORTS = %w[
      call-with-input-file call-with-output-file delete-file file-exists?
      open-binary-input-file open-binary-output-file open-input-file open-output-file
      with-input-from-file with-output-to-file
    ]

    SCHEME_LOAD_EXPORTS = %w[load]

    SCHEME_PROCESS_CONTEXT_EXPORTS = %w[command-line emergency-exit exit get-environment-variable get-environment-variables]

    SCHEME_CASE_LAMBDA_EXPORTS = %w[case-lambda]

    SCHEME_TIME_EXPORTS = %w[current-jiffy current-second jiffies-per-second]

    private def install_sub_libraries : Nil
      char_env = Env.new
      install_string_upcase_downcase(char_env) # string-upcase/downcase live in (creme string) too; (scheme char) needs its own copy since it's not auto-imported from there.
      register_library(["scheme", "char"], char_env, SCHEME_CHAR_EXPORTS.to_h { |name| {name, name} })

      # (scheme inexact)'s trig/log functions are Crystal-native and only
      # otherwise reachable via the non-standard (creme math); sqrt/finite?/
      # infinite?/nan? are already core (scheme base) builtins, so this
      # library's Env borrows those from @base_env by copy (not a chain) —
      # each SchemeLibrary Env is independent per the design decision in
      # library.cr, so a direct binding copy (not import_bindings, which
      # would be circular here since @base_env isn't itself a SchemeLibrary
      # export source for non-base names) is simplest.
      inexact_env = Env.new
      install_math(inexact_env)
      %w[sqrt finite? infinite? nan?].each { |name| inexact_env.define(name, @base_env.get(name)) }
      register_library(["scheme", "inexact"], inexact_env, SCHEME_INEXACT_EXPORTS.to_h { |name| {name, name} })

      cxr_env = Env.new
      install_cxr(cxr_env)
      register_library(["scheme", "cxr"], cxr_env, SCHEME_CXR_EXPORTS.to_h { |name| {name, name} })

      lazy_env = Env.new
      SCHEME_LAZY_EXPORTS.each { |name| lazy_env.define(name, name == "delay" || name == "delay-force" ? SchemeSpecialForm.new(name) : @base_env.get(name)) }
      register_library(["scheme", "lazy"], lazy_env, SCHEME_LAZY_EXPORTS.to_h { |name| {name, name} })

      read_env = Env.new
      read_env.define("read", @base_env.get("read"))
      register_library(["scheme", "read"], read_env, SCHEME_READ_EXPORTS.to_h { |name| {name, name} })

      eval_env = Env.new
      SCHEME_EVAL_EXPORTS.each { |name| eval_env.define(name, @base_env.get(name)) }
      register_library(["scheme", "eval"], eval_env, SCHEME_EVAL_EXPORTS.to_h { |name| {name, name} })

      repl_env = Env.new
      SCHEME_REPL_EXPORTS.each { |name| repl_env.define(name, @base_env.get(name)) }
      register_library(["scheme", "repl"], repl_env, SCHEME_REPL_EXPORTS.to_h { |name| {name, name} })

      r5rs_env = Env.new
      SCHEME_R5RS_EXPORTS.each { |name| r5rs_env.define(name, @base_env.get(name)) }
      register_library(["scheme", "r5rs"], r5rs_env, SCHEME_R5RS_EXPORTS.to_h { |name| {name, name} })

      # (scheme file)'s procedures are already fully implemented as (creme
      # file) (see modules/file.cr) — this is a second, independent
      # registration of the same installer under the R7RS-standard library
      # name, exporting just the subset R7RS itself specifies (creme file
      # additionally has file-read/file-write/file-append/file-lines/
      # file-size, non-standard whole-file convenience helpers that stay
      # creme-only).
      file_env = Env.new
      install_file(file_env)
      register_library(["scheme", "file"], file_env, SCHEME_FILE_EXPORTS.to_h { |name| {name, name} })

      load_env = Env.new
      install_load(load_env)
      register_library(["scheme", "load"], load_env, SCHEME_LOAD_EXPORTS.to_h { |name| {name, name} })

      process_context_env = Env.new
      install_process(process_context_env)
      install_env(process_context_env)
      process_context_env.define("exit", @base_env.get("exit"))
      process_context_env.define("emergency-exit", @base_env.get("exit"))
      register_library(["scheme", "process-context"], process_context_env, SCHEME_PROCESS_CONTEXT_EXPORTS.to_h { |name| {name, name} })

      case_lambda_env = Env.new
      case_lambda_env.define("case-lambda", @base_env.get("case-lambda"))
      register_library(["scheme", "case-lambda"], case_lambda_env, SCHEME_CASE_LAMBDA_EXPORTS.to_h { |name| {name, name} })

      time_env = Env.new
      install_scheme_time(time_env)
      register_library(["scheme", "time"], time_env, SCHEME_TIME_EXPORTS.to_h { |name| {name, name} })
    end

    private def install_string_upcase_downcase(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(SchemeValue) -> SchemeValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end
      reg.call("string-upcase", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeStr.new(string_ext_arg(args[0], "string-upcase").upcase) })
      reg.call("string-downcase", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeStr.new(string_ext_arg(args[0], "string-downcase").downcase) })
      reg.call("string-foldcase", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeStr.new(string_ext_arg(args[0], "string-foldcase").downcase) })
      %w[char-alphabetic? char-ci<=? char-ci<? char-ci=? char-ci>=? char-ci>? char-downcase char-foldcase
        char-lower-case? char-numeric? char-upcase char-upper-case? char-whitespace? digit-value
        string-ci<=? string-ci<? string-ci=? string-ci>=? string-ci>?].each do |name|
        env.define(name, @base_env.get(name))
      end
    end

    # The 24 car/cdr compositions R7RS Appendix A scopes to (scheme cxr):
    # every 3- and 4-level composition, including caddr/cdddr/cadddr —
    # confirmed against the spec text (only the four 2-level compositions,
    # caar/cadr/cdar/cddr, are (scheme base) exports; a prior version of
    # this comment incorrectly assumed caddr/cdddr/cadddr were base too).
    # prelude.cr still defines caddr/cdddr/cadddr directly in @base_env for
    # backward compatibility with existing unprefixed usage — this
    # installer additionally exposes them (and the other 21) through the
    # real (scheme cxr) library for code that imports properly.
    private def install_cxr(env : Env) : Nil
      names = %w[
        caaaar caaadr caaar caadar caaddr caadr cadaar cadadr cadar caddar
        cadddr caddr cdaaar cdaadr cdaar cdadar cdaddr cdadr cddaar cddadr
        cddar cdddar cddddr cdddr
      ]
      names.each do |name|
        ops = name[1..-2].chars.reverse! # "caaaar" -> "aaaar" minus trailing r -> steps innermost-first
        env.define(name, Builtin.new(name, 1, 1) do |args|
          v = args[0]
          ops.each do |op|
            raise SchemeRuntimeError.new("#{name}: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
            v = op == 'a' ? v.car : v.cdr
          end
          v
        end)
      end
    end

    private def install_scheme_time(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(SchemeValue) -> SchemeValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end
      reg.call("current-second", 0, 0, ->(_args : Array(SchemeValue)) : SchemeValue { SchemeFloat.new(Time.utc.to_unix_f) })
      reg.call("current-jiffy", 0, 0, ->(_args : Array(SchemeValue)) : SchemeValue { SchemeInt.new((Time.instant - start_instant).total_microseconds.to_i64) })
      reg.call("jiffies-per-second", 0, 0, ->(_args : Array(SchemeValue)) : SchemeValue { SchemeInt.new(1_000_000_i64) })
    end
  end
end
