;; ===========================================================================
;; (creme highlight): ANSI syntax highlighting and paren-balance checking for
;; a Scheme REPL input line, built on (creme scheme-lexer)'s real tokenizer
;; rather than hand-rolled character scanning -- see that library's own
;; header comment, and examples/24-tui-try-scheme.scm's scheme-highlight-line
;; (the naive predecessor this is meant to eventually replace there: no
;; escape-aware strings, no block comments, no nested-comment support).
;; File-based, same rationale as (creme scheme-lexer)'s own header comment.
;;
;;   (highlight-line str) -> str, unchanged in content but with each token's
;;                            text wrapped in an ANSI SGR color escape based
;;                            on its (creme scheme-lexer) token kind. Same
;;                            "\x1b;[CODEm...\x1b;[0m" idiom (creme spec)'s
;;                            spec-colorize already uses for portable ANSI
;;                            in this project -- see that library's own
;;                            header comment. A symbol in HEAD position --
;;                            immediately after an open paren, e.g. `display`
;;                            in `(display "hello")` -- gets the same color
;;                            as a recognized keyword, matching the common
;;                            editor convention of coloring the called
;;                            procedure's name distinctly from an ordinary
;;                            argument symbol, even when it's an ordinary
;;                            procedure rather than a special form. Every
;;                            other plain/uncolored kind (symbol not in head
;;                            position, whitespace, unknown) is passed
;;                            through with NO wrapping at all, so stripping
;;                            every ANSI escape back out of the result
;;                            always reconstructs the original `str` exactly
;;                            (verified in spec/creme scripts alongside this
;;                            library).
;;
;;   (paren-balance str)   -> a status pair (cons depth status) describing
;;                            whether `str` is a complete, submittable REPL
;;                            buffer:
;;
;;       status is one of:
;;         'complete              every open was closed, no dangling string
;;                                 or block comment; depth is always 0 here.
;;         'open                  well-formed so far but depth opens are
;;                                 still unclosed; depth is that net open
;;                                 count (>= 1) -- meant to drive a live
;;                                 continuation-prompt indicator (e.g.
;;                                 printing "...depth" for each pending
;;                                 close).
;;         'unterminated-string    str ends in the middle of a "..." literal.
;;         'unterminated-comment   str ends in the middle of a #| ... |#
;;                                 block comment.
;;
;;       depth only carries meaningful information for 'open (the running
;;       open/close-token count; bracket TYPE mismatches like "(" closed by
;;       "]" are deliberately not tracked -- v1 only tracks a single
;;       combined depth, see (creme scheme-lexer)'s own open/close kinds).
;;       For 'unterminated-string / 'unterminated-comment, depth is simply
;;       whatever the open/close count happened to be at the point the
;;       unterminated token was hit (not meaningful on its own -- the
;;       status already says "needs more input" regardless of depth).
;;
;;       A caller's "ready to submit" check is exactly:
;;         (and (eq? (cdr (paren-balance str)) 'complete))
;;       (depth is always 0 whenever status is 'complete, by construction,
;;       so testing status alone is sufficient -- but the pair still
;;       carries depth uniformly across every status for a caller that
;;       wants to just read (car ...) unconditionally.)
;; ===========================================================================

(define-library (creme highlight)
  (export highlight-line paren-balance)
  (import (scheme base) (creme scheme-lexer))
  (begin

    (define (colorize code text)
      (string-append "\x1b;[" code "m" text "\x1b;[0m"))

    ;; R7RS's syntactic-keyword set, as already recognized by this project's
    ;; own (builtin base) -- see src/scheme/modules/scheme/base.cr's
    ;; BUILTIN_BASE_NONFN -- extended with a few more common syntactic forms
    ;; (define-record-type, case, do, delay/delay-force/make-promise,
    ;; syntax-rules, case-lambda, λ) that aren't in that exact list but are
    ;; still reader-visible keywords a highlighter should color, matching
    ;; examples/24-tui-try-scheme.scm's own naive keyword list's intent
    ;; (just more complete).
    (define scheme-keywords
      (list "define" "lambda" "λ" "if" "cond" "when" "unless"
            "let" "let*" "letrec" "letrec*" "let-values" "let*-values"
            "let-syntax" "letrec-syntax" "define-syntax" "syntax-rules"
            "begin" "and" "or" "quote" "quasiquote" "unquote" "unquote-splicing"
            "set!" "define-values" "define-record-type" "case" "case-lambda"
            "do" "guard" "parameterize" "cond-expand"
            "delay" "delay-force" "make-promise"
            "require" "defmacro"))

    (define (keyword? text) (if (member text scheme-keywords) #t #f))

    ;; A symbol immediately in "head position" -- the first thing after an
    ;; open paren, e.g. `display` in `(display "hello")` -- gets the same
    ;; treatment as a keyword, matching the common editor convention of
    ;; coloring the operator/procedure-name position distinctly from an
    ;; ordinary argument symbol, even when it isn't one of this project's
    ;; own recognized syntactic keywords.
    (define (token-color kind text head?)
      (case kind
        ((symbol) (if (or head? (keyword? text)) "1;34" #f))
        ((string unterminated-string) "32")
        ((char) "36")
        ((number) "35")
        ((boolean) "36")
        ((open close) "2")
        ((line-comment block-comment unterminated-block-comment datum-comment) "2")
        ((quote-mark) "33")
        (else #f))) ; whitespace, unknown: no color

    ;; Tracks whether the NEXT significant (non-whitespace, non-comment)
    ;; token is in head position -- true only right after an `open` token,
    ;; and reset by any other significant token (so only the very first
    ;; symbol in a list is colored, not every symbol in it).
    (define (highlight-line str)
      (let loop ((tokens (scheme-tokenize str)) (head? #f) (acc '()))
        (if (null? tokens)
            (apply string-append (reverse acc))
            (let* ((tok (car tokens)) (kind (car tok)) (text (cdr tok)))
              (case kind
                ((whitespace) (loop (cdr tokens) head? (cons text acc)))
                ((line-comment block-comment unterminated-block-comment datum-comment)
                 (loop (cdr tokens) head? (cons (colorize (token-color kind text #f) text) acc)))
                (else
                 (let* ((code (token-color kind text head?))
                        (piece (if code (colorize code text) text))
                        (next-head? (eq? kind 'open)))
                   (loop (cdr tokens) next-head? (cons piece acc)))))))))

    (define (paren-balance str)
      (let loop ((tokens (scheme-tokenize str)) (depth 0))
        (if (null? tokens)
            (cons depth (if (> depth 0) 'open 'complete))
            (let* ((tok (car tokens)) (kind (car tok)))
              (case kind
                ((open) (loop (cdr tokens) (+ depth 1)))
                ((close) (loop (cdr tokens) (- depth 1)))
                ((unterminated-string)
                 (if (null? (cdr tokens)) (cons depth 'unterminated-string) (loop (cdr tokens) depth)))
                ((unterminated-block-comment)
                 (if (null? (cdr tokens)) (cons depth 'unterminated-comment) (loop (cdr tokens) depth)))
                (else (loop (cdr tokens) depth)))))))))
