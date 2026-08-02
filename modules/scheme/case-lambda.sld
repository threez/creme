;; (scheme case-lambda): thin re-export frontend over (creme builtin case-lambda)
(define-library (scheme case-lambda)
  (import (creme builtin case-lambda))
  (export case-lambda))
