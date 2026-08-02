;; (creme term): thin re-export frontend over (creme builtin term)
(define-library (creme term)
  (import (creme builtin term))
  (export term-raw-mode-enter! term-raw-mode-exit! term-read-key term-move-cursor! term-clear-to-eol! term-write! stdout-tty? stdin-tty?))
