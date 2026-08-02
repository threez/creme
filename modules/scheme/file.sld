;; ===========================================================================
;; (scheme file): thin re-export frontend over (creme builtin file) —
;; the R7RS-standard SUBSET only (10 names). See modules/creme/file.sld for
;; the full creme-only superset (also file-read/file-write/file-append/
;; current-directory/file-lines/file-size).
;; ===========================================================================

(define-library (scheme file)
  (import (creme builtin file))
  (export file-exists? delete-file open-input-file open-output-file
          open-binary-input-file open-binary-output-file
          call-with-input-file call-with-output-file
          with-input-from-file with-output-to-file))
