;; (creme yaml): thin re-export frontend over (creme builtin yaml)
(define-library (creme yaml)
  (import (creme builtin yaml))
  (export yaml-read yaml-write))
