;; ===========================================================================
;; (creme syntax scss): a Sass/SCSS-flavored `#lang` dialect over (creme css)
;;
;; File-based (no FFI of its own — same rationale as modules/creme/
;; numfmt.sld's header comment), built on top of `(creme reader)`'s sibling
;; approach for a grammar that ISN'T token-stream-shaped: unlike `(creme
;; syntax mex)`, SCSS's lexical rules don't fit Scheme's own Lexer at all (`;` is
;; a Scheme line-comment starter, `{`/`}`/`:` aren't meaningful Scheme
;; delimiters) — so this is a recursive-descent parser built declaratively
;; on `(creme peg)`'s parser combinators, exactly the "truly alien
;; grammar" escape hatch described in src/scheme/runner.cr's `#lang` doc
;; comment. No new Crystal surface at all. Only the statement/nesting/
;; comment-skipping GRAMMAR is expressed as combinators; a decl's own
;; "property : value" splitting and $variable substitution stay ordinary
;; string-manipulation helpers, called from the grammar's own actions --
;; combinators earn their keep on the recursive structural part, not
;; every last bit of text handling.
;;
;; Scope (deliberately not full Sass): nesting (selector { ... } blocks,
;; with (creme css)'s own existing "&" parent-selector handling — this
;; parser doesn't combine selectors itself, it just preserves each rule's
;; own selector text and lets (creme css)'s css-render do that job, same
;; as it already does for hand-written (creme css) rule data), a single
;; global `$name: value;` variable mechanism (substituted into later
;; declaration values textually, in encounter order — not Sass's real
;; lexically-scoped variables), and `//`/`/* */` comments. NOT supported:
;; @mixin/@include/@extend, interpolation (#{...}), parent selector
;; combinators beyond a leading "&", math/functions on values. Comments
;; are only recognized between statements, not embedded inside a
;; selector's or declaration value's own text (so e.g. `font: 12px/1.5;`
;; is unambiguous — that "/" is never mistaken for a comment opener).
;;
;; A `#lang (creme syntax scss)` file's whole content is exactly one stylesheet.
;; Two ways to use it (see src/scheme/runner.cr's `#lang` doc comment for
;; the header-args contract this implements):
;;   ./bin/creme style.scss                -- no `(export ...)` on the
;;                                             header line -> prints the
;;                                             compiled CSS to stdout (a
;;                                             quick standalone demo)
;;   (load "style.scss")                   -- with `#lang (creme syntax scss)
;;                                             (export css)` as the
;;                                             header line -> defines
;;                                             css as the compiled CSS
;;                                             string in the loading
;;                                             environment, same as
;;                                             (define css (css! ...))
;;                                             did by hand before
;; All $variables are already resolved to plain strings at parse time, so
;; either way the compiled result is fully static text, not a template.
;;
;; (scss->string src) is the same parse-and-compile step exported as an
;; ordinary procedure, for a caller that wants the compiled CSS text
;; directly without going through the #lang mechanism at all.
;;
;; Example:
;;   $accent: #888;
;;   .todo-app {
;;     max-width: 28rem;
;;     .title { color: $accent; }
;;     &.done { opacity: 0.6; }
;;   }
;; ===========================================================================

(define-library (creme syntax scss)
  (export read-program scss->string)
  (import (scheme base) (scheme char) (creme string) (creme css) (creme scanner) (creme peg))
  (begin
    ;; ---- variable table -----------------------------------------------
    ;; A fresh alist per read-program call (no cross-call state) — SCSS
    ;; variables here are simple "define once, substitute textually from
    ;; here on" globals, not real lexical scoping.

    (define (make-var-table) (list '()))
    (define (var-table-set! table name value)
      (set-car! table (cons (cons name value) (car table))))
    (define (var-table-ref table name)
      (let ((found (assoc name (car table))))
        (if found (cdr found) (error "scss: undefined variable" name))))

    ;; Replaces every "$identifier" run inside `value` with its current
    ;; value from `table` (identifier chars: alphanumeric, "-", "_").
    (define (substitute-vars value table)
      (define out (open-output-string))
      (define len (string-length value))
      (let loop ((i 0))
        (if (>= i len)
            (get-output-string out)
            (let ((c (string-ref value i)))
              (if (char=? c #\$)
                  (let scan ((j (+ i 1)))
                    (if (and (< j len) (ident-char? (string-ref value j)))
                        (scan (+ j 1))
                        (begin
                          (write-string (var-table-ref table (substring value (+ i 1) j)) out)
                          (loop j))))
                  (begin (write-char c out) (loop (+ i 1))))))))

    ;; A SRFI-1-style filter, kept local same as (creme css)'s own (see
    ;; its header comment) to keep this module's imports minimal.
    (define (filter pred lst)
      (cond ((null? lst) '())
            ((pred (car lst)) (cons (car lst) (filter pred (cdr lst))))
            (else (filter pred (cdr lst)))))

    ;; ---- grammar (creme peg) ---------------------------------------------
    ;;
    ;;   stylesheet := statement*
    ;;   statement   := skip-ws-comments head-text ("{" stylesheet "}" | ";")
    ;;   head-text   := (char not in "{;}")*
    ;;
    ;; i.e. a statement's own head is everything up to the first
    ;; unnested "{"/";"/"}"; which one follows decides whether it's a
    ;; nested rule (recursing for the "{...}" body) or a flat
    ;; declaration/$variable-definition (parse-decl decides which, and
    ;; returns #f for the latter -- filtered out of the result below,
    ;; same as the original hand-written scanner did).

    (define line-comment
      (peg-seq (peg-lit "//") (peg-while (lambda (c) (not (char=? c #\newline))))))

    (define block-comment
      (peg-seq (peg-lit "/*") (peg-until-lit "*/")
               (peg-must (peg-lit "*/") "scss: unterminated /* comment */")))

    (define skip-ws-comments
      (peg-many (peg-alt (peg-char-pred char-whitespace?) line-comment block-comment)))

    (define head-text (peg-while (lambda (c) (not (memv c (list #\{ #\; #\}))))))

    ;; (make-stylesheet-parser table) -> a parser for a run of statements,
    ;; stopping at (but not consuming) a "}" or EOF without erroring --
    ;; used both for the top-level stylesheet and, recursively, for a
    ;; nested rule's own body.
    (define (make-stylesheet-parser table)
      (letrec
          ((rule-tail
            (peg-seq-map (list (peg-skip (peg-lit "{")) (peg-lazy (lambda () stylesheet))
                                (peg-skip skip-ws-comments)
                                (peg-skip (peg-must (peg-lit "}") "scss: expected '}'")))
                         (lambda (body) (cons 'rule body))))
           (decl-tail
            (peg-map (peg-must (peg-lit ";") "scss: expected ';' or '{'") (lambda (v) (list 'decl))))
           (statement
            (peg-seq-map
             (list (peg-skip skip-ws-comments) (peg-skip (peg-not (peg-eof)))
                   (peg-skip (peg-not (peg-lit "}"))) head-text (peg-alt rule-tail decl-tail))
             (lambda (head tail)
               (let ((head (string-trim head)))
                 (if (eq? (car tail) 'rule)
                     (cons (parse-selector head) (cdr tail))
                     (parse-decl head table))))))
           (stylesheet
            (peg-map (peg-many statement) (lambda (items) (filter (lambda (x) x) items)))))
        stylesheet))

    ;; Splits a selector on top-level commas into a list of trimmed parts
    ;; -- (creme css) accepts either a bare string or a list of strings.
    (define (parse-selector head)
      (let ((parts (map string-trim (string-split head ","))))
        (if (null? (cdr parts)) (car parts) parts)))

    ;; head is "property : value" (or "$name : value"). Returns a decl
    ;; item ready for (creme css) if it's an ordinary declaration, or #f
    ;; if it was a $variable definition (already stored into table).
    (define (parse-decl head table)
      (let* ((colon (or (string-index-of head ":") (error "scss: expected ':' in declaration" head)))
             (prop (string-trim (substring head 0 colon)))
             (raw-value (string-trim (substring head (+ colon 1) (string-length head))))
             (value (substitute-vars raw-value table)))
        (if (and (> (string-length prop) 0) (char=? (string-ref prop 0) #\$))
            (begin (var-table-set! table (substring prop 1 (string-length prop)) value) #f)
            (list (string->symbol prop) value))))

    (define (parse-stylesheet src)
      (peg-run (peg-seq-map (list (make-stylesheet-parser (make-var-table)) (peg-skip skip-ws-comments))
                            (lambda (stmts) stmts))
               src))

    ;; (scss->string src) -> the compiled CSS text for stylesheet `src`,
    ;; an ordinary procedure usable outside the #lang mechanism entirely.
    (define (scss->string src)
      (css->string (parse-stylesheet src)))

    ;; The #lang contract (see src/scheme/runner.cr): src is everything in
    ;; the file after the `#lang` line; the result is a proper list of
    ;; ordinary forms. No `(export name)` among header-args (run
    ;; standalone) -> print the compiled CSS; `(export name)` present
    ;; (typically reached via `(load ...)`) -> define that name to the
    ;; compiled CSS string instead of printing anything.
    (define (read-program src source-name header-args)
      (let ((export-form (assq 'export header-args)))
        (if (not export-form)
            (list
             '(import (creme css) (scheme write) (scheme base))
             (list 'css-render '(current-output-port) (list 'quote (parse-stylesheet src))))
            (list
             '(import (scheme base))
             (list 'define (cadr export-form) (scss->string src))))))))
