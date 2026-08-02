# ===========================================================================
# R7RS (scheme ...) sub-libraries: manifest
# ===========================================================================
#
# Each gets its own fresh (non-@base_env) Env, same as (scheme base)/(scheme
# write) themselves get (see modules/scheme/base.cr) but WITHOUT the
# auto-import special case — these must be explicitly (import ...)ed,
# matching R7RS (only base/write are ever auto-imported, and only when
# Interpreter.new(auto_import_base: true), a deliberate deviation
# documented in modules/scheme/base.cr). (builtin base)/(builtin write) are
# the actual @base_env-identity libraries now.
#
# Every actual registration lives declaratively in each library's own file
# under src/creme/modules/scheme/, via a `register_library [...]` (or
# block-form) call directly in that file's own class body — this file is
# just the header comment for the group; there is no wiring method here
# (see builtin_registration.cr's `LIB_DECLS`/`macro finished`).
