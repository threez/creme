# ===========================================================================
# (creme ...): this project's own non-standard libraries
# ===========================================================================
#
# Every custom Crystal-native module (bigdecimal, digest, json, regex, sql,
# tui, rfc8439, http, hash-table, string, random, format, env, process,
# math, time) gets registered here under the `(creme <name>)` namespace,
# replacing the old (require 'name) mechanism (require.cr is removed in
# Stage 6, once every caller has migrated). `(creme math)`/`(creme time)`
# are supersets of (scheme inexact)/(scheme time) — their original, larger
# Crystal-native export sets (log2/log10/atan2/pow/hypot/pi/e; the rich
# epoch/format time API) are untouched, just re-registered under a new name.
#
# Each library gets its own fresh Env (none are auto-imported), following
# the same pattern established in sub_libraries.cr.
#
# Two `(creme ...)` libraries are pure R7RS Scheme with no Crystal FFI/
# opaque-object involvement and so live as file-based .sld libraries
# instead, resolved via library_search_path rather than registered here:
# modules/creme/sxql.sld and modules/creme/extra.sld (this project's own
# SRFI-1-style/prelude conveniences — filter/reduce/println/first/etc.).

module Scheme
  class Interpreter
    CREME_BIGDECIMAL_EXPORTS = %w[
      string->bigdecimal integer->bigdecimal bigdecimal-add bigdecimal-sub bigdecimal-mul
      bigdecimal-div bigdecimal-neg bigdecimal-compare bigdecimal=? bigdecimal<? bigdecimal>?
      bigdecimal-zero? bigdecimal->string bigdecimal?
    ]
    CREME_MATH_EXPORTS  = %w[sin cos tan asin acos atan log log2 log10 exp atan2 pow hypot pi e]
    CREME_REGEX_EXPORTS = %w[regexp regexp-matches? regexp-search regexp-extract regexp-replace regexp-replace-all regexp-split regexp?]
    CREME_JSON_EXPORTS  = %w[json-read json-write]
    CREME_FILE_EXPORTS  = %w[
      file-read file-write file-append file-exists? delete-file file-lines file-size
      open-input-file open-output-file call-with-input-file call-with-output-file
      with-input-from-file with-output-to-file
    ]
    CREME_TIME_EXPORTS = %w[
      current-time time-year time-month time-day time-hour time-minute time-second
      time->string string->time time-add time-difference
    ]
    CREME_STRING_EXPORTS = %w[
      string-upcase string-downcase string-trim string-reverse string-split string-join
      string-replace string-contains? string-prefix? string-suffix? string-index-of
      string-repeat string-pad string-pad-right
    ]
    CREME_FORMAT_EXPORTS  = %w[format]
    CREME_RANDOM_EXPORTS  = %w[random-real random-integer random-seed! random-choice random-shuffle]
    CREME_DIGEST_EXPORTS  = %w[digest-md5 digest-sha1 digest-sha256 base64-encode base64-decode]
    CREME_ENV_EXPORTS     = %w[get-environment-variable set-environment-variable! delete-environment-variable! environment-variable-set? get-environment-variables]
    CREME_PROCESS_EXPORTS = %w[process-run command-line]
    CREME_SQL_EXPORTS     = %w[sql-open sql-close sql-execute sql-query sql-scalar sql-connection?]
    CREME_TUI_EXPORTS     = %w[
      tui-color-named tui-color-index tui-color-rgb tui-color-gray tui-style tui-screen
      tui-buffer-set! tui-buffer-clear! tui-buffer-box! tui-text-edit tui-text-edit-value
      tui-text-edit-set-highlighter! tui-make-scrollable tui-window tui-vstack
      tui-vstack-set-bottom! tui-handle-key! tui-run
    ]
    CREME_RFC8439_EXPORTS = %w[
      rfc8439-random-key rfc8439-random-nonce hex->bytevector bytevector->hex rfc8439-encrypt
      rfc8439-decrypt chacha20-encrypt poly1305-auth
    ]
    CREME_HTTP_EXPORTS       = %w[http-get http-head http-delete http-post http-put http-patch http-request]
    CREME_HASH_TABLE_EXPORTS = %w[make-hash-table hash-table? hash-table-set! hash-table-ref hash-table-delete! hash-table-contains? hash-table-keys hash-table-values hash-table->alist]

    # macro?/gensym: the two names (creme extra) deliberately left behind
    # when it moved to modules/creme/extra.sld (see that file's header
    # comment) — genuine Crystal-level operations with no R7RS
    # equivalent, so they can't be expressed in a portable .sld. Both
    # already live in @base_env (via install_builtins); this library
    # borrows them by copy, same pattern (scheme char)/(scheme inexact)
    # use in sub_libraries.cr.
    CREME_INTROSPECTION_EXPORTS = %w[macro? gensym]

    private def install_creme_libraries : Nil
      register_installed_library(["creme", "bigdecimal"], CREME_BIGDECIMAL_EXPORTS) { |e| install_bigdecimal(e) }
      register_installed_library(["creme", "math"], CREME_MATH_EXPORTS) { |e| install_math(e) }
      register_installed_library(["creme", "regex"], CREME_REGEX_EXPORTS) { |e| install_regex(e) }
      register_installed_library(["creme", "json"], CREME_JSON_EXPORTS) { |e| install_json(e) }
      register_installed_library(["creme", "file"], CREME_FILE_EXPORTS) { |e| install_file(e) }
      register_installed_library(["creme", "time"], CREME_TIME_EXPORTS) { |e| install_time(e) }
      register_installed_library(["creme", "string"], CREME_STRING_EXPORTS) { |e| install_string_ext(e) }
      register_installed_library(["creme", "format"], CREME_FORMAT_EXPORTS) { |e| install_format(e) }
      register_installed_library(["creme", "random"], CREME_RANDOM_EXPORTS) { |e| install_random(e) }
      register_installed_library(["creme", "digest"], CREME_DIGEST_EXPORTS) { |e| install_digest(e) }
      register_installed_library(["creme", "env"], CREME_ENV_EXPORTS) { |e| install_env(e) }
      register_installed_library(["creme", "process"], CREME_PROCESS_EXPORTS) { |e| install_process(e) }
      register_installed_library(["creme", "sql"], CREME_SQL_EXPORTS) { |e| install_sql(e) }
      register_installed_library(["creme", "tui"], CREME_TUI_EXPORTS) { |e| install_tui(e) }
      register_installed_library(["creme", "rfc8439"], CREME_RFC8439_EXPORTS) { |e| install_rfc8439(e) }
      register_installed_library(["creme", "http"], CREME_HTTP_EXPORTS) { |e| install_http(e) }
      register_installed_library(["creme", "hash-table"], CREME_HASH_TABLE_EXPORTS) { |e| install_hash_table(e) }

      introspection_env = Env.new
      CREME_INTROSPECTION_EXPORTS.each { |name| introspection_env.define(name, @base_env.get(name)) }
      register_library(["creme", "introspection"], introspection_env, CREME_INTROSPECTION_EXPORTS.to_h { |name| {name, name} })
    end

    private def register_installed_library(name : Array(String), exports : Array(String), & : Env ->) : SchemeLibrary
      env = Env.new
      yield env
      register_library(name, env, exports.to_h { |export_name| {export_name, export_name} })
    end
  end
end
