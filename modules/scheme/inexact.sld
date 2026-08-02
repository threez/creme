;; (scheme inexact): thin re-export frontend over (creme builtin inexact)
(define-library (scheme inexact)
  (import (creme builtin inexact))
  (export acos asin atan cos exp finite? infinite? log nan? sin sqrt tan))
