;; (creme format): thin re-export frontend over (creme builtin format)
(define-library (creme format)
  (import (creme builtin format))
  (export format))
