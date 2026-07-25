;; ===========================================================================
;; A REPL for cvm, depending at runtime on nothing but this file's own
;; precompiled SCB1 image -- no live Crystal `creme` process is involved
;; after the one-time build below.
;; ===========================================================================
;;
;; The self-hosted compiler (modules/creme/compiler/{reader,bytecode,
;; compiler}.sld) already compiles Scheme source into the exact SCB1 bytes
;; cvm reads natively; the only piece that was missing was a way to load-
;; and-run a freshly-computed bytevector of those bytes from WITHIN an
;; already-running cvm program -- cvm/bootstrap.c's `load-chunk-bytes`
;; (mirroring (creme bootstrap)'s Crystal-side builtin of the same name).
;; This file just loops: read one line, compile it with the bundled
;; compiler, run the result against this SAME program's own global table
;; (so `(define x 5)` on one line and `(display x)` on the next resolve to
;; the same global, exactly like an ordinary REPL), print the value.
;;
;; Build once, then run interactively:
;;   ./bin/creme --emit-cvm cvm/repl.scm cvm/repl.cvmc
;;   ./cvm/cvm cvm/repl.cvmc
;;
;; Scope (v1): one top-level form per line -- no multi-line input. A
;; paren-balance-based line-accumulation loop is a natural follow-up, not
;; needed for the core deliverable.
;;
;; Macro limitation: a session can define and use its OWN define-syntax/
;; defmacro macros (the compiler's own macro-table is an ordinary mutable
;; Scheme variable in this loaded image, so it persists naturally across
;; lines), but can never use a macro that was only defined inside a
;; flattened/precompiled library baked into THIS image (e.g. sxql-select!
;; from (creme sxql), if this image happened to import it) -- see
;; cvm/bootstrap.c's own `expand-if-macro` for why that's an inherent
;; boundary of this design, not a bug.
(import (scheme base) (scheme write) (scheme lazy)
        (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler))

(define (repl)
  (display "cvm> ")
  (let ((line (read-line)))
    ;; cvm's own read-line uses plain #f as its EOF marker (it has no real
    ;; eof-object/eof-object? -- see cvm/builtins.c's bi_read_line), unlike
    ;; the real interpreter's dedicated EOF singleton.
    (unless (eq? line #f)
      (guard (e (#t (display "error: ")
                    (display (if (error-object? e) (error-object-message e) e))
                    (newline)))
        (unless (string=? line "")
          (display (load-chunk-bytes (compile-source-to-bytes line)))
          (newline)))
      (repl))))

(repl)
