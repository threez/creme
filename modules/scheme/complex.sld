;; (scheme complex): thin re-export frontend over (creme builtin complex)
(define-library (scheme complex)
  (import (creme builtin complex))
  (export angle complex? imag-part magnitude make-polar make-rectangular real-part))
