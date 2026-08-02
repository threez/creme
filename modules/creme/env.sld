;; (creme env): thin re-export frontend over (creme builtin env)
(define-library (creme env)
  (import (creme builtin env))
  (export delete-environment-variable! environment-variable-set?
          get-environment-variable get-environment-variables
          set-environment-variable!))
