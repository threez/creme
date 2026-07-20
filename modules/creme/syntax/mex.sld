;; ===========================================================================
;; (creme syntax mex): adjacency-based M-expression application syntax --
;;   f(x y)   desugars to   (f x y)
;; -- as a `#lang (creme syntax mex)` dialect (see src/scheme/runner.cr's `#lang`
;; handling). No second bracket character: the disambiguator is purely
;; lexical adjacency -- is there a character gap between the symbol and
;; the `(`? `f (x y)` (WITH a space) is NOT sugar; it reads as two
;; separate forms (the symbol f and the data list (x y)), exactly as it
;; does without this dialect. See examples/todo.mex for a full worked
;; example.
;;
;; File-based (no FFI of its own — same rationale as modules/creme/
;; numfmt.sld's header comment), but built on top of `(creme reader)`
;; (src/scheme/modules/creme/reader.cr), which IS Crystal-native: it
;; exposes the real Lexer/Reader to Scheme as a token-stream hook so the
;; dialect-specific transform below (the actual "parser" for this
;; syntax) can be genuine Scheme code, while lexical grammar (numbers,
;; string escapes, comments, ...) stays exactly where it's already
;; correct. lex-tokens/tokens->forms are (creme reader)'s only two
;; exports this file relies on.
;; ===========================================================================

(define-library (creme syntax mex)
  (export read-program)
  (import (scheme base) (scheme cxr) (creme reader))
  (begin
    (define (token-kind tok) (car tok))
    (define (token-text tok) (cadr tok))
    (define (token-line tok) (caddr tok))
    (define (token-col tok) (cadddr tok))

    ;; True when token b starts exactly where token a's text ends -- same
    ;; line, zero characters (not even a space or comment) in between.
    (define (mex-adjacent? a b)
      (and (= (token-line a) (token-line b))
           (= (+ (token-col a) (string-length (token-text a))) (token-col b))))

    ;; One left-to-right pass over the token list: wherever a symbol token
    ;; is immediately followed by an adjacent open-paren token, swap the
    ;; two. That's the entire transform -- `f(x y)`'s tokens
    ;;   (symbol-f) (lparen) (symbol-x) (symbol-y) (rparen)
    ;; become
    ;;   (lparen) (symbol-f) (symbol-x) (symbol-y) (rparen)
    ;; i.e. precisely the token list for `(f x y)`. Everything between the
    ;; lparen and its matching rparen stays exactly where it was, so this
    ;; needs no paren-matching/nesting bookkeeping and composes correctly
    ;; for nested or chained adjacency (`g(f(x))`, `f(x)(y)`) for free --
    ;; the unmodified Reader, run afterward (via tokens->forms), does the
    ;; rest.
    (define (mex-desugar-tokens tokens)
      (cond
        ((null? tokens) '())
        ((null? (cdr tokens)) tokens)
        (else
         (let ((cur (car tokens)) (nxt (cadr tokens)))
           (if (and (eq? (token-kind cur) 'symbol)
                    (eq? (token-kind nxt) 'lparen)
                    (mex-adjacent? cur nxt))
               (cons nxt (cons cur (mex-desugar-tokens (cddr tokens))))
               (cons cur (mex-desugar-tokens (cdr tokens))))))))

    ;; The #lang contract this dialect implements (see src/scheme/
    ;; runner.cr): src is everything in the file after the `#lang` line;
    ;; the result is a proper list of ordinary forms, ready for the
    ;; analyzer/compiler/VM exactly as if the plain Reader had produced
    ;; them. header-args is unused here -- a whole mex program is always a
    ;; list of forms to run for effect, run standalone or loaded alike.
    (define (read-program src source-name header-args)
      (tokens->forms (mex-desugar-tokens (lex-tokens src source-name)) source-name))))
