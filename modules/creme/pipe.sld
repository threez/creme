;; ===========================================================================
;; (creme pipe): Elixir-style |> pipeline threading, spelled `pipe`
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme sxql)/(creme extra) use) since the whole thing is one small
;; syntax-rules macro with no opaque foreign object or Crystal FFI
;; involved.
;;
;; Named `pipe` rather than the literal `|>` token: this project's reader
;; treats a leading `|` as the start of a `|...|` piped/quoted identifier
;; (see src/creme/read/lexer.cr's lex_piped_identifier), the same
;; mechanism `#|...|#` block comments piggyback on for their closing
;; delimiter, so a bare `|>` symbol isn't lexable as-is.
;;
;; (pipe x step ...) threads x through each step left to right: a bare
;; identifier step is called as (step acc); a list step (f arg ...) is
;; called as (f acc arg ...) — acc spliced in as f's first argument,
;; matching Elixir's `|>` semantics exactly. Unhygienic like every
;; syntax-rules macro in this project, but that's harmless here since
;; the macro only rearranges the caller's own forms and introduces no
;; new bindings.
;;
;; Example: (pipe 5 (+ 1) (* 2) - ) => (- (* 2 (+ 5 1)))  => -12
;; ===========================================================================

(define-library (creme pipe)
  (export pipe)
  (import (scheme base))
  (begin
    (define-syntax pipe
      (syntax-rules ()
        ((_ x) x)
        ((_ x (f arg ...) rest ...) (pipe (f x arg ...) rest ...))
        ((_ x f rest ...) (pipe (f x) rest ...))))))
