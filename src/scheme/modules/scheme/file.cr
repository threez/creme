# ===========================================================================
# (scheme file)
# ===========================================================================
#
# (scheme file)'s procedures are already fully implemented as (creme file)
# (see modules/creme/file.cr) — this is a second, independent registration
# of the same installer under the R7RS-standard library name, exporting
# just the subset R7RS itself specifies (creme file additionally has
# file-read/file-write/file-append/file-lines/file-size, non-standard
# whole-file convenience helpers that stay creme-only).

module Scheme
  class Interpreter
    # register_module(FileLibrary, ...) (modules/creme/file.cr) installs the
    # full richer (creme file) surface into env — (scheme file) only EXPORTS
    # the R7RS subset below, so this can't be derived from that call's own
    # return value the way most other libraries' exports are.
    SCHEME_FILE_EXPORTS = %w[
      call-with-input-file call-with-output-file delete-file file-exists?
      open-binary-input-file open-binary-output-file open-input-file open-output-file
      with-input-from-file with-output-to-file
    ]

    register_library ["scheme", "file"] do |env|
      register_module(Scheme::Builtins::FileLibrary, env)
      SCHEME_FILE_EXPORTS
    end
  end
end
