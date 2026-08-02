;; (creme regex): thin re-export frontend over (creme builtin regex)
(define-library (creme regex)
  (import (creme builtin regex))
  (export regexp regexp-extract regexp-matches? regexp-replace
          regexp-replace-all regexp-search regexp-split regexp?))
