;; (creme secure-random): thin re-export frontend over (creme builtin secure-random)
(define-library (creme secure-random)
  (import (creme builtin secure-random))
  (export secure-random-bytes secure-random-hex secure-random-base64))
