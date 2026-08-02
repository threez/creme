;; (creme tui): thin re-export frontend over (creme builtin tui)
(define-library (creme tui)
  (import (creme builtin tui))
  (export tui-buffer-box! tui-buffer-clear! tui-buffer-set! tui-color-gray
          tui-color-index tui-color-named tui-color-rgb tui-handle-key!
          tui-make-scrollable tui-run tui-screen tui-style tui-text-edit
          tui-text-edit-set-highlighter! tui-text-edit-value tui-vstack
          tui-vstack-set-bottom! tui-window))
