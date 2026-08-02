;; (creme bigdecimal): thin re-export frontend over (creme builtin bigdecimal)
(define-library (creme bigdecimal)
  (import (creme builtin bigdecimal))
  (export bigdecimal->string bigdecimal-add bigdecimal-compare bigdecimal-div
          bigdecimal-mul bigdecimal-neg bigdecimal-sub bigdecimal-zero?
          bigdecimal<? bigdecimal=? bigdecimal>? bigdecimal? integer->bigdecimal
          string->bigdecimal))
