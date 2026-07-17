# ===========================================================================
# (creme ...): this project's own non-standard libraries
# ===========================================================================
#
# Every custom Crystal-native module (bigdecimal, digest, json, regex, sql,
# tui, rfc8439, http, hash-table, string, random, format, env, process,
# math, time, prof, introspection) is registered declaratively via a
# `register_library [...]` call directly in that module's own file under
# src/scheme/modules/creme/ — this file now only holds this group's header
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
