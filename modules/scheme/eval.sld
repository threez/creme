;; (scheme eval): thin re-export frontend over (creme builtin eval)
(define-library (scheme eval)
  (import (creme builtin eval))
  (export environment eval))
