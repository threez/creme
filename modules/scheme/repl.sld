;; (scheme repl): thin re-export frontend over (creme builtin repl)
(define-library (scheme repl)
  (import (creme builtin repl))
  (export interaction-environment))
