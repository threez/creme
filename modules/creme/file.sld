;; ===========================================================================
;; (creme file): thin re-export frontend over (creme builtin file) — the
;; full superset, R7RS's (scheme file) subset (see modules/scheme/file.sld)
;; plus the creme-only whole-file conveniences (file-read/file-write/
;; file-append/current-directory/file-lines/file-size).
;; ===========================================================================

(define-library (creme file)
  (import (creme builtin file))
  (export call-with-input-file call-with-output-file current-directory
          delete-file file-append file-exists? file-lines file-read
          file-size file-write open-binary-input-file open-binary-output-file
          open-input-file open-output-file with-input-from-file
          with-output-to-file))
