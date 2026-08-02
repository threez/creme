;; (creme json): thin re-export frontend over (creme builtin json)
(define-library (creme json)
  (import (creme builtin json))
  (export json-read json-write))
