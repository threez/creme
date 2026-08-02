;; ===========================================================================
;; (scheme lazy): thin re-export frontend over (creme builtin lazy)
;;
;; delay/delay-force are special forms (SchemeSpecialForm markers bound via
;; env.define, not annotated methods — see src/creme/modules/scheme/lazy.cr)
;; but the native family's register_library block already folds their names
;; into its own exports table, so a plain re-export works uniformly for all
;; five names with no special-casing needed here.
;; ===========================================================================

(define-library (scheme lazy)
  (import (creme builtin lazy))
  (export delay delay-force force make-promise promise?))
