# ===========================================================================
# R7RS (scheme ...) sub-libraries: manifest
# ===========================================================================
#
# Each gets its own fresh (non-@base_env) Env, following (scheme base)'s
# pattern from modules/scheme/base.cr but WITHOUT the auto-import special
# case — these must be explicitly (import ...)ed, matching R7RS (only
# base/write are ever auto-imported, and only when
# Interpreter.new(auto_import_base: true), a deliberate deviation
# documented in modules/scheme/base.cr).
#
# Every actual registration lives declaratively in each library's own file
# under src/scheme/modules/scheme/, via a `register_library [...]` (or
# block-form) call directly in that file's own class body — this file is
# just the header comment for the group; there is no wiring method here
# (see builtin_registration.cr's `LIB_DECLS`/`macro finished`).
