# ===========================================================================
# (scheme file)
# ===========================================================================
#
# (scheme file)'s procedures are exactly Scheme::Builtins::FileLibrary
# (modules/creme/file.cr) — the R7RS-standard subset. (creme file)
# additionally registers Scheme::Builtins::FileExtra (file-read/file-write/
# file-append/file-lines/file-size/current-directory), the non-standard
# whole-file conveniences that stay creme-only. Both libraries derive their
# exports from register_module, so there is no hand-maintained subset list.

module Scheme
  class Interpreter
    register_library ["scheme", "file"], Scheme::Builtins::FileLibrary
  end
end
