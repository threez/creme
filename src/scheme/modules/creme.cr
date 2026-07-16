# ===========================================================================
# (creme ...): this project's own non-standard libraries
# ===========================================================================
#
# Every custom Crystal-native module (bigdecimal, digest, json, regex, sql,
# tui, rfc8439, http, hash-table, string, random, format, env, process,
# math, time, prof) is registered declaratively via a `register_library
# [...]` call directly in that module's own file under
# src/scheme/modules/creme/ — this file only holds the one library
# (introspection) with no module file of its own, plus this group's header
# comment. `(creme math)`/`(creme time)` are supersets of (scheme inexact)/
# (scheme time) — their original, larger Crystal-native export sets
# (log2/log10/atan2/pow/hypot/pi/e; the rich epoch/format time API) are
# untouched, just re-registered under a new name.
#
# Five `(creme ...)` libraries are pure R7RS Scheme with no Crystal FFI/
# opaque-object involvement and so live as file-based .sld libraries
# instead, resolved via library_search_path rather than registered here:
# modules/creme/sxql.sld, modules/creme/extra.sld (this project's own
# SRFI-1-style/prelude conveniences — filter/reduce/println/first/etc.),
# modules/creme/table.sld (bordered/borderless table rendering via
# pluggable styles), modules/creme/html.sld (HTML escaping + a table
# style), and modules/creme/numfmt.sld (fixed-decimal/ratio number
# formatting).

module Scheme
  class Interpreter
    # macro?/gensym: the two names (creme extra) deliberately left behind
    # when it moved to modules/creme/extra.sld (see that file's header
    # comment) — genuine Crystal-level operations with no R7RS
    # equivalent, so they can't be expressed in a portable .sld. Both
    # already live in @base_env (via install_builtins); this library
    # borrows them by copy, same pattern (scheme char)/(scheme inexact)
    # use under modules/scheme/.
    register_library ["creme", "introspection"] do |env|
      names = %w[macro? gensym]
      names.each { |name| env.define(name, @base_env.get(name)) }
      names
    end
  end
end
