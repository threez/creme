;; ===========================================================================
;; (creme syntax slim): a Slim-flavored `#lang` dialect over (creme html)
;;
;; File-based (no FFI of its own — same rationale as modules/creme/
;; numfmt.sld's header comment). Like (creme syntax scss), this hand-writes a
;; recursive-descent parser straight from characters (indentation-
;; sensitive syntax has no token-stream-shaped equivalent to reuse from
;; (creme reader)/Scheme's own Lexer) — see src/scheme/runner.cr's `#lang`
;; doc comment for that split. No new Crystal surface at all.
;;
;; Scope (deliberately not full Slim): indentation-based nesting (2, 4,
;; any consistent width — whatever a block's first child line uses is
;; that block's indent for the rest of its siblings), tag/class/id
;; shorthand (div.todo-app#main, or a bare .class/#id defaulting to div),
;; attributes in parens -- static (input(type="text")), dynamic
;; (li(class=(if done "done" "pending"))), or a bare valueless name for
;; a boolean-true attribute (input(required)) -- static text content
;; (whatever remains on a tag's own line after shorthand/attrs), and `=`
;; for splicing a Scheme expression's value in as a child — either as
;; its own line (`= expr`, no tag) or attached after a tag/attrs head
;; (`tag ... = expr`, the tag's sole dynamic child) — the direct
;; equivalent of a quasiquote template's ,expr, since these files
;; commonly need to render live data (a css variable, a loop over rows,
;; a conditional label) rather than pure static markup. NOT supported:
;; control-code lines, verbatim text blocks, comments, tabs (leading
;; whitespace must be spaces).
;;
;; A `#lang (creme syntax slim)` file's whole content is exactly one document
;; fragment. Two ways to use it (see src/scheme/runner.cr's `#lang` doc
;; comment for the header-args contract this implements):
;;   ./bin/creme page.slim            -- no `(export ...)` on the header
;;                                        line -> renders straight to
;;                                        stdout (a quick standalone
;;                                        demo); any `=` expression is
;;                                        evaluated against whatever's
;;                                        already defined in the running
;;                                        program
;;   (load "row.slim")                -- with `#lang (creme syntax slim)
;;                                        (export row) (params id done
;;                                        title)` as the header line ->
;;                                        defines `row` as an ORDINARY
;;                                        PROCEDURE of exactly those
;;                                        params, e.g. (row id done
;;                                        title), returning the rendered
;;                                        HTML string -- a genuine
;;                                        reusable, parameterized
;;                                        template, the same role AND
;;                                        THE SAME PERFORMANCE
;;                                        CHARACTERISTIC as (define
;;                                        (todo-row->string id done
;;                                        title) (html! `(...))) played
;;                                        by hand before: the template
;;                                        text is parsed and the
;;                                        resulting node tree compiled to
;;                                        bytecode exactly ONCE, when the
;;                                        file is loaded -- calling `row`
;;                                        is then an ordinary,
;;                                        already-compiled procedure
;;                                        call, id/done/title resolved as
;;                                        real (fast) parameter
;;                                        references, not an alist
;;                                        looked up at render time. A
;;                                        `#lang (creme syntax slim) (export
;;                                        row) (params id done title)
;;                                        (import (creme path))` header
;;                                        adds `(creme path)` (or any
;;                                        other libraries) to what's
;;                                        visible to the template's own
;;                                        `=` expressions, on top of the
;;                                        always-available (scheme base).
;;                                        No `(params ...)` at all -> a
;;                                        zero-argument procedure (a
;;                                        template with no free
;;                                        variables at all still needs
;;                                        calling, for uniformity).
;;
;; Example (row.slim, loaded, then called as (row id done title)):
;;   #lang (creme syntax slim) (export row) (params id done title) (import (creme path) (creme format))
;;   li(class=(if done "done" "pending"))
;;     span.title = title
;;     button(type="submit") = (if done "Undo" "Done")
;;
;; slim->tree/slim-render/slim->string/slim-render-with/slim->string-with
;; are also exported, for the rarer case of a template whose text is only
;; known at RUNTIME (e.g. read from a database) rather than from a #lang
;; file with a static, known-ahead-of-time parameter list -- these
;; re-parse the template text and re-analyze/compile its node tree on
;; EVERY call (via `eval`), which is real, unavoidable overhead for that
;; use case; prefer the #lang (params ...) path above whenever the
;; parameter set is known statically, which is the common case.
;; ===========================================================================

(define-library (creme syntax slim)
  (export read-program slim->tree slim-render slim->string slim-render-with slim->string-with)
  (import (scheme base) (scheme char) (scheme cxr) (scheme read) (scheme eval) (creme string) (creme html) (creme scanner) (creme peg))
  (begin
    (define (strip-cr line)
      (let ((n (string-length line)))
        (if (and (> n 0) (char=? (string-ref line (- n 1)) #\return))
            (substring line 0 (- n 1))
            line)))

    (define (line-indent line)
      (let loop ((i 0))
        (if (and (< i (string-length line)) (char=? (string-ref line i) #\space))
            (loop (+ i 1))
            i)))

    (define (blank-line? line) (= 0 (string-length (string-trim line))))

    ;; Splits src into a list of (indent . content) pairs, one per
    ;; non-blank line, content already stripped of its leading indent
    ;; (and any trailing \r).
    (define (scan-lines src)
      (let loop ((lines (string-split src "\n")) (acc '()))
        (if (null? lines)
            (reverse acc)
            (let ((line (strip-cr (car lines))))
              (if (blank-line? line)
                  (loop (cdr lines) acc)
                  (let ((indent (line-indent line)))
                    (loop (cdr lines)
                          (cons (cons indent (substring line indent (string-length line))) acc))))))))

    ;; ---- per-line head grammar (creme peg): tag/class/id/attrs/text ----
    ;;
    ;;   tag-head   := tag-name (class-item | id-item)* attrs? rest-of-line
    ;;   tag-name   := ident, or "div" (zero-width, not consumed) if the
    ;;                 line starts with "." or "#" (shorthand)
    ;;   class-item := "." ident
    ;;   id-item    := "#" ident   -- the LAST one wins if several appear
    ;;   attrs      := "(" (ws attr)* ws ")"
    ;;   attr       := ident ("=" attr-value)?   -- no "=value" at all is
    ;;                 a bare boolean-true attribute (input(required))
    ;;   attr-value := "(" expr ")"              -- a dynamic Scheme
    ;;                                              expression (spliced
    ;;                                              in via unquote)
    ;;              |  '"' chars '"'             -- a static string
    ;;              |  (non-space non-")" char)+ -- a static bareword

    ;; A SRFI-1-style filter, kept local same as (creme syntax scss)'s
    ;; own (see (creme css)'s header comment for the shared rationale).
    (define (filter pred lst)
      (cond ((null? lst) '())
            ((pred (car lst)) (cons (car lst) (filter pred (cdr lst))))
            (else (filter pred (cdr lst)))))

    (define ident (peg-while ident-char?))
    ;; A NON-empty run of ident chars -- unlike `ident` above, this can
    ;; never match a zero-width empty string. Required specifically for
    ;; `attr`'s own name below: `attr` is used under peg-many (inside
    ;; `attrs`), and a sub-parser that can succeed while consuming
    ;; nothing (e.g. `ident` matching "" right at the closing ")") would
    ;; make that peg-many loop forever, retrying the same non-advancing
    ;; position endlessly.
    (define ident1 (peg-map (peg-many1 (peg-char-pred ident-char?)) list->string))
    (define ws-sp (peg-while (lambda (c) (char=? c #\space))))

    ;; A "(...)" value is a Scheme expression to evaluate dynamically,
    ;; e.g. class=(if done "done" "pending") -- peg-balanced-parens
    ;; consumes the whole balanced expression however deeply nested,
    ;; then it's handed to the real reader as its own isolated string,
    ;; exactly like a `=` line's own embedded expression does.
    (define attr-value
      (peg-alt
       (peg-map (peg-balanced-parens) (lambda (text) (list 'unquote (read (open-input-string text)))))
       (peg-seq-map (list (peg-skip (peg-lit "\"")) (peg-until-lit "\"")
                          (peg-skip (peg-must (peg-lit "\"") "slim: unterminated attribute value")))
                    (lambda (text) text))
       (peg-while (lambda (c) (not (or (char-whitespace? c) (char=? c #\))))))))

    ;; A name with no "=value" at all is a bare boolean-true attribute
    ;; (e.g. input(required)), matching (creme html)'s own #t attribute-
    ;; value convention -- peg-opt's own #f (no "=..." present at all)
    ;; and an explicit attr-value are told apart directly, since
    ;; attr-value itself never produces #f as a genuine matched value.
    (define attr
      (peg-seq-map
       (list ident1 (peg-opt (peg-seq-map (list (peg-skip (peg-lit "=")) attr-value) (lambda (v) v))))
       (lambda (name value) (list (string->symbol name) (if value value #t)))))

    ;; Comma-free, space-separated (name[=value] ...) run in parens.
    (define attrs
      (peg-seq-map
       (list (peg-skip (peg-lit "("))
             (peg-many (peg-seq-map (list (peg-skip ws-sp) attr) (lambda (a) a)))
             (peg-skip ws-sp)
             (peg-skip (peg-must (peg-lit ")") "slim: expected ')'")))
       (lambda (attr-list) attr-list)))

    (define (dot-or-hash? c) (or (char=? c #\.) (char=? c #\#)))
    (define tag-name
      (lambda (str pos)
        (if (and (< pos (string-length str)) (dot-or-hash? (string-ref str pos)))
            (cons "div" pos)
            (ident str pos))))

    (define class-item (peg-seq-map (list (peg-skip (peg-lit ".")) ident) (lambda (name) (cons 'class name))))
    (define id-item (peg-seq-map (list (peg-skip (peg-lit "#")) ident) (lambda (name) (cons 'id name))))
    (define class-or-id-list (peg-many (peg-alt class-item id-item)))

    (define rest-of-line (peg-while (lambda (c) #t)))

    (define tag-head-parser
      (peg-seq-map
       (list tag-name class-or-id-list (peg-opt attrs) rest-of-line)
       (lambda (tag class-or-id attrs-opt text)
         (let* ((classes (map cdr (filter (lambda (p) (eq? (car p) 'class)) class-or-id)))
                (id (let loop ((items class-or-id) (found #f))
                      (cond
                        ((null? items) found)
                        ((eq? (car (car items)) 'id) (loop (cdr items) (cdr (car items))))
                        (else (loop (cdr items) found)))))
                (attrs-val (or attrs-opt '())))
           (list tag classes id attrs-val (string-trim text))))))

    ;; Parses one non-"=" line's own content (tag/class/id/attrs/text)
    ;; into (list tag classes id attrs text) -- tag-head-parser's own
    ;; final rest-of-line piece always consumes to the end, so peg-run's
    ;; "consumed everything" check is exactly the right thing here.
    (define (parse-tag-head content) (peg-run tag-head-parser content))

    (define (build-attrs-block classes id attrs)
      (let ((class-attr (if (null? classes) '() (list (list 'class (string-join classes " ")))))
            (id-attr (if id (list (list 'id id)) '())))
        (cons '@ (append class-attr id-attr attrs))))

    ;; Turns one line (its own text plus its already-parsed child nodes)
    ;; into a (creme html) node. A "=" line splices a Scheme expression's
    ;; value in via unquote instead of building a tag.
    (define (line->node content children)
      (if (and (> (string-length content) 0) (char=? (string-ref content 0) #\=))
          (begin
            (unless (null? children) (error "slim: '=' lines cannot have children" content))
            (list 'unquote (read (open-input-string (string-trim (substring content 1 (string-length content)))))))
          (let* ((parsed (parse-tag-head content))
                 (tag (car parsed))
                 (classes (cadr parsed))
                 (id (caddr parsed))
                 (attrs (cadddr parsed))
                 (text (car (cddddr parsed)))
                 (attrs-block (build-attrs-block classes id attrs))
                 ;; `tag ... = expr` (an inline "=" after the tag/attrs
                 ;; head, e.g. `span.title = title`) splices that
                 ;; expression's value as this tag's own dynamic child,
                 ;; same as a standalone "=" line does at top level.
                 (text-nodes
                  (cond
                   ((= (string-length text) 0) '())
                   ((char=? (string-ref text 0) #\=)
                    (list (list 'unquote (read (open-input-string (string-trim (substring text 1 (string-length text))))))))
                   (else (list text)))))
            (cons (string->symbol tag) (cons attrs-block (append text-nodes children))))))

    ;; Consumes a run of sibling lines all sharing the SAME indent (the
    ;; first remaining line's own indent, which must be >= min-indent),
    ;; each with its own nested children (lines indented deeper than that
    ;; shared indent) -- returns (cons nodes remaining-lines). Stops at
    ;; the first line indented less than that shared level, or at EOF.
    (define (parse-siblings lines min-indent)
      (if (or (null? lines) (< (caar lines) min-indent))
          (cons '() lines)
          (let ((level-indent (caar lines)))
            (let loop ((lines lines) (acc '()))
              (if (null? lines)
                  (cons (reverse acc) lines)
                  (let ((indent (caar lines)))
                    (cond
                      ((< indent level-indent) (cons (reverse acc) lines))
                      ;; Not reachable in practice: the preceding sibling's
                      ;; own recursive child-result call (min-indent
                      ;; level-indent+1) already consumes every line
                      ;; indented deeper than level-indent, however deep —
                      ;; kept as a defensive fallback in case that
                      ;; invariant ever breaks.
                      ((> indent level-indent) (error "slim: unexpected indent" (cdar lines)))
                      (else
                       (let* ((content (cdar lines))
                              (child-result (parse-siblings (cdr lines) (+ level-indent 1)))
                              (children (car child-result))
                              (after (cdr child-result))
                              (node (line->node content children)))
                         (loop after (cons node acc)))))))))))

    ;; (slim->tree src) -> the parsed template AS SYNTAX, i.e. a
    ;; `(quasiquote node-tree)` form ready to `eval`. Multiple top-level
    ;; sibling lines work fine as-is -- (creme html)'s node grammar
    ;; already treats a list whose car isn't a symbol as a fragment,
    ;; which a plain list of parsed nodes satisfies whether it holds one
    ;; node or many.
    (define (slim->tree src)
      (list 'quasiquote (car (parse-siblings (scan-lines src) 0))))

    ;; (slim-render src env) -> the actual (creme html) node value for
    ;; template `src`, with every "=" expression evaluated against `env`
    ;; -- build one via (environment '(scheme base) ...) and inject
    ;; per-call bindings with (eval (list 'define name (list 'quote
    ;; value)) env) first, or just use slim-render-with below.
    (define (slim-render src env)
      (eval (slim->tree src) env))

    ;; (slim->string src env) -> slim-render's result, rendered to a
    ;; string via (creme html)'s html->string.
    (define (slim->string src env)
      (html->string (slim-render src env)))

    ;; (slim-render-with src imports bindings) -> builds its own fresh
    ;; environment (imports, a list of import-set forms e.g. '((scheme
    ;; base) (creme path)), plus each (name . value) pair in `bindings`
    ;; defined into it), then slim-renders `src` against it -- the
    ;; reusable-template entry point: parse once, call many times with
    ;; different bindings.
    (define (slim-render-with src imports bindings)
      (let ((env (apply environment imports)))
        (for-each (lambda (b) (eval (list 'define (car b) (list 'quote (cdr b))) env)) bindings)
        (slim-render src env)))

    (define (slim->string-with src imports bindings)
      (html->string (slim-render-with src imports bindings)))

    ;; The #lang contract (see src/scheme/runner.cr): src is everything in
    ;; the file after the `#lang` line; the result is a proper list of
    ;; ordinary forms. No `(export name)` among header-args (run
    ;; standalone) -> render straight to stdout, "=" expressions
    ;; evaluated against whatever's already defined in the running
    ;; program; `(export name)` present -> define that name as an
    ;; ordinary procedure of whatever `(params ...)` header-arg gives (or
    ;; zero arguments if omitted) -- the template is parsed and its node
    ;; tree analyzed/compiled to bytecode exactly ONCE, as part of this
    ;; returned `define` form itself, not per call (see the library's own
    ;; header comment for why this matters). An optional `(import
    ;; lib-set ...)` header-arg adds extra import-sets, on top of the
    ;; always-available (scheme base) and (creme html), for the
    ;; template's own "=" expressions to use.
    (define (read-program src source-name header-args)
      (let ((export-form (assq 'export header-args)))
        (if (not export-form)
            (list
             '(import (scheme base) (scheme write) (creme html))
             (list 'html-write! '(current-output-port) (slim->tree src)))
            (let* ((params-form (assq 'params header-args))
                   (params (if params-form (cdr params-form) '()))
                   (import-form (assq 'import header-args))
                   (extra-imports (if import-form (cdr import-form) '())))
              (list
               (cons 'import (cons '(scheme base) (cons '(creme html) extra-imports)))
               ;; html! (not html->string): a defmacro that folds every
               ;; static part of this same quasiquote syntax into plain
               ;; string literals at macro-expansion time -- i.e. right
               ;; now, while THIS returned define form is itself being
               ;; analyzed/compiled -- leaving only the genuinely
               ;; dynamic pieces (the ones referencing params) to
               ;; compute per call. html->string is the generic runtime
               ;; walker instead: correct, but it re-walks and
               ;; re-type-dispatches the ENTIRE tree on every single
               ;; call, including the parts that never change between
               ;; calls -- exactly the gap that kept this slower than
               ;; the hand-written html! version it replaces.
               (list 'define (cons (cadr export-form) params)
                     (list 'html! (slim->tree src))))))))))
