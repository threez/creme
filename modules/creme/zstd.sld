;; (creme zstd): thin re-export frontend over (creme builtin zstd)
(define-library (creme zstd)
  (import (creme builtin zstd))
  (export zstd-compress zstd-decompress
          zstd-open-output-port zstd-open-input-port))
