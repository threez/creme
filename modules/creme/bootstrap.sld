;; (creme bootstrap): thin re-export frontend over (creme builtin bootstrap)
(define-library (creme bootstrap)
  (import (creme builtin bootstrap))
  (export expand-if-macro import! load-chunk-bytes))
