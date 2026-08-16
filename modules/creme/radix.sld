;; (creme radix): thin re-export frontend over (creme builtin radix)
(define-library (creme radix)
  (import (creme builtin radix))
  (export radix-tree radix-tree? radix-tree-set! radix-tree-ref
          radix-tree-match radix-tree-count))
