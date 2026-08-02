;; (scheme write): thin re-export frontend over (creme builtin write)
(define-library (scheme write)
  (import (creme builtin write))
  (export display write write-shared write-simple))
