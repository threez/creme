;; (scheme read): thin re-export frontend over (creme builtin read)
(define-library (scheme read)
  (import (creme builtin read))
  (export read))
