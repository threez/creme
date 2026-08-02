# ===========================================================================
# (scheme file) / (creme file)
# ===========================================================================
#
# (scheme file)'s procedures are exactly Creme::Builtins::FileLibrary
# (modules/creme/file.cr) — the R7RS-standard subset. (creme file)
# additionally registers Creme::Builtins::FileExtra (file-read/file-write/
# file-append/file-lines/file-size/current-directory), the non-standard
# whole-file conveniences that stay creme-only. Both are now merged into the
# single native registration ["creme", "builtin", "file"] (see
# modules/creme/file.cr, which registers FileLibrary + FileExtra together) —
# nothing left to register here.
