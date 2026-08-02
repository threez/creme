;; ===========================================================================
;; cvm's own REPL is now just a thin driver over the shared (creme repl)
;; library (modules/creme/repl.sld) -- the same run-repl entry point the
;; native Crystal interpreter and --self-hosted mode also delegate to, so
;; all three runtimes share one implementation instead of each maintaining
;; their own line-editor/highlighting/error-formatting logic.
;;
;; Run directly as source (do NOT precompile via --emit-cvm: (creme repl)
;; needs (scheme read)/(scheme eval)/(interaction-environment), which are
;; only backed by cvm's self-hosted compiler-mode bridge when this file is
;; loaded as raw source -- a standalone precompiled .cvmc has no such
;; bridge and crashes with "unbound variable: read" the moment a form is
;; submitted):
;;   ./cvm/cvm cvm/repl.scm
;; ===========================================================================
(import (scheme process-context) (creme repl))

(run-repl)
