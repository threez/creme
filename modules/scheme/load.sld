;; (scheme load): thin re-export frontend over (creme builtin load)
(define-library (scheme load)
  (import (creme builtin load))
  (export load))
