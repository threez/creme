;; (creme random): thin re-export frontend over (creme builtin random)
(define-library (creme random)
  (import (creme builtin random))
  (export random-choice random-integer random-real random-seed! random-shuffle))
