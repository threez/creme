;; (creme hardware): thin re-export frontend over (creme builtin hardware)
(define-library (creme hardware)
  (import (creme builtin hardware))
  (export hardware-info))
