;; ===========================================================================
;; (creme css): a small, data-driven CSS builder with Sass-style nesting
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme html)/(creme sxql)/(creme extra) use) rather than compiled into the
;; interpreter binary, since every export here is expressible in plain R7RS
;; with no opaque foreign object, stateful handle, or third-party Crystal
;; library involved — see modules/creme/extra.sld's own header comment for
;; the same rationale.
;;
;; A stylesheet is plain nested list data (a "rule"), same design language
;; as (creme html)'s Hiccup-style node grammar: rules may nest other rules,
;; each nested selector combined with its parent's to build the final
;; selector — the main reason to reach for this over a hand-written string
;; is exactly that selector-building: writing ".todo-app" once and nesting
;; ".title"/"&.active" underneath instead of repeating the parent prefix on
;; every rule.
;;
;; grammar:
;;   stylesheet ::= a list of rules
;;   rule       ::= (selector item ...)   -- selector: a string, or a list
;;                                           of strings for a comma-separated
;;                                           selector group, e.g.
;;                                           '("th" "td") -> "th, td"
;;                | (raw string ...)      -- unescaped, concatenated
;;                                           verbatim (e.g. an @media block
;;                                           or anything else not covered by
;;                                           the grammar above)
;;   item       ::= decl | rule                (see below for how they're
;;                                               told apart)
;;   decl       ::= (property value)      -- property: a symbol (hyphenated
;;                                           symbols work as-is: font-family,
;;                                           text-decoration) or string;
;;                                           value: a string (used verbatim,
;;                                           e.g. "1px solid black") or a
;;                                           number (number->string'd, for
;;                                           unitless properties like
;;                                           line-height/z-index)
;;
;; A rule's items are told apart from plain declarations structurally, with
;; no extra marker needed: a decl is always exactly a 2-element (property
;; value) list whose value is an atom (string/number); anything else —
;; more than 2 elements, or a non-atom second element — is a nested rule.
;; So (color "red") is a decl, but (".title" (color "red")) is a nested
;; rule (its second element, (color "red"), is itself a list).
;;
;; A nested rule's own selector is combined with its parent's before being
;; emitted as a separate, top-level CSS rule (exactly like Sass/Less
;; compile nesting): if the nested selector starts with "&", "&" is
;; replaced with the parent selector (no separating space — for compound
;; selectors like "&.active" or "&:hover"); otherwise the nested selector
;; is joined to the parent with a descendant combinator (a space). Nesting
;; is unlimited-depth; a selector that's a comma-separated group at either
;; level combines as the full cross-product, e.g. nesting '("a" "b") under
;; '("x" "y") produces the four rules "x a", "x b", "y a", "y b".
;;
;; No escaping is performed anywhere — selectors/property names/values are
;; taken to be well-formed CSS text, matching how (creme html) doesn't
;; escape attribute *names* either (only text content and attribute
;; *values* are escaped there).
;;
;;   (css-render port rules)  -> writes rules' serialization into port
;;   (css->string rules)      -> renders rules against a fresh string port,
;;                                returns the accumulated string
;;   (css! rules)             -> a defmacro, same contract as css->string
;;                                but folds every part of `rules` that's
;;                                free of ,expr/,@expr into a plain string
;;                                literal AT MACRO-EXPANSION TIME, leaving
;;                                only genuinely dynamic seams (a decl
;;                                value, or a whole dynamic rule) to render
;;                                at runtime — since real stylesheets are
;;                                almost always 100% static, this usually
;;                                folds the ENTIRE thing to one literal.
;;                                Any script calling css! must itself
;;                                (import (creme css)) directly, even if it
;;                                only reaches (creme css) transitively via
;;                                (creme html) — a defmacro transformer body
;;                                always runs against this interpreter's
;;                                single shared @global env, not its
;;                                defining library's own env, so the helper
;;                                procedures css! calls while expanding must
;;                                already be visible there
;;   (css-write! port rules)  -> the same folding as css!, but writing
;;                                directly into an already-open `port`
;;                                instead of creating a fresh one — for a
;;                                caller that already has a port to write
;;                                into (e.g. streaming an HTTP response
;;                                body via (creme mux)); returns
;;                                unspecified, not a string. Same
;;                                @global-visibility requirement as css!
;;
;; Like (creme html)'s html-render/html->string, this is a port-based
;; recursive builder rather than plain string concatenation, for the same
;; reason: writing N fragments into one shared growable-buffer port is
;; O(total output size), not O(n^2) the way repeated string-append would be.
;;
;; Example:
;;
;;   (css->string
;;    `((body (font-family "sans-serif"))
;;      (".todo-app"
;;       (max-width "28rem")
;;       (margin "2rem auto")
;;       (".title" (text-decoration "line-through") (color "#888"))
;;       ("&.done" (opacity "0.6")))
;;      ((".form.toggle" ".form.delete") (display "inline"))))
;;   ;; => ".todo-app { max-width: 28rem; margin: 2rem auto; }
;;   ;;     .todo-app .title { text-decoration: line-through; color: #888; }
;;   ;;     .todo-app.done { opacity: 0.6; }
;;   ;;     ..." (plus the other two top-level rules)
;;
;; Not auto-imported anywhere — every script that wants any of this must
;; (import (creme css)) explicitly, same as any other file-based library.
;; ===========================================================================

(define-library (creme css)
  (export css-fold-rules css-pieces->body css-render css->string css! css-write! write-decl)
  (import (scheme base) (scheme write) (creme string) (only (creme extra) filter))
  (begin
    (define (decl-name->string name)
      (if (symbol? name) (symbol->string name) name))

    (define (decl-value->string value)
      (if (string? value) value (number->string value)))

    (define (write-decl port decl)
      (write-string "  " port)
      (write-string (decl-name->string (car decl)) port)
      (write-string ": " port)
      (write-string (decl-value->string (cadr decl)) port)
      (write-string ";\n" port))

    ;; A decl is exactly (property value) with value an atom; anything
    ;; else (more items, or a non-atom second item) is a nested rule.
    (define (nested-rule-item? item)
      (or (pair? (cddr item)) (pair? (cadr item))))

    (define (selector-atom->string selector)
      (if (symbol? selector) (symbol->string selector) selector))

    (define (selector->string selector)
      (if (pair? selector)
          (string-join (map selector-atom->string selector) ", ")
          (selector-atom->string selector)))

    (define (as-selector-list selector)
      (map selector-atom->string (if (pair? selector) selector (list selector))))

    (define (combine-one parent child)
      (if (and (> (string-length child) 0) (char=? (string-ref child 0) #\&))
          (string-append parent (substring child 1 (string-length child)))
          (string-append parent " " child)))

    ;; Combines a nested rule's selector with its parent's — the
    ;; full cross-product when either side is a comma-separated group —
    ;; collapsing back to a single string when there's only one result.
    (define (combine-selectors parent child)
      (let* ((parents (as-selector-list parent))
             (children (as-selector-list child))
             (combined (apply append
                               (map (lambda (p)
                                      (map (lambda (c) (combine-one p c)) children))
                                    parents))))
        (if (null? (cdr combined)) (car combined) combined)))

    ;; (css-render port rules) -> writes rules' serialization directly into
    ;; `port`, one rule at a time (including any of its own nested rules,
    ;; recursively, each emitted as its own separate top-level CSS rule).
    (define (css-render port rules)
      (for-each (lambda (rule) (write-rule port rule)) rules))

    (define (write-rule port rule)
      (if (eq? (car rule) 'raw)
          (write-string (apply string-append (cdr rule)) port)
          (write-rule-items port (car rule) (cdr rule))))

    (define (write-rule-items port selector items)
      (let ((decls (filter (lambda (i) (not (nested-rule-item? i))) items))
            (nested (filter nested-rule-item? items)))
        (if (pair? decls)
            (begin
              (write-string (selector->string selector) port)
              (write-string " {\n" port)
              (for-each (lambda (decl) (write-decl port decl)) decls)
              (write-string "}\n" port)))
        (for-each
         (lambda (n) (write-rule-items port (combine-selectors selector (car n)) (cdr n)))
         nested)))

    ;; (css->string rules) -> renders rules against a fresh string port,
    ;; returns the accumulated string.
    (define (css->string rules)
      (let ((port (open-output-string)))
        (css-render port rules)
        (get-output-string port)))

    ;; ---- compile-time template folding (css!) -------------------------------
    ;;
    ;; Mirrors (creme html)'s html-fold exactly in spirit (see that file's
    ;; header comment for the general approach) -- pieces are (lit . str) or
    ;; (code . expr), literal syntax free of ,expr/,@expr anywhere folds by
    ;; calling the real css-render directly on the raw syntax at expansion
    ;; time. The one CSS-specific wrinkle: a decl's value position may be a
    ;; pair even when static (that's how a NESTED RULE is told apart from a
    ;; plain decl at runtime -- see nested-rule-item? above), so folding
    ;; needs its own syntax-level decl-vs-nested-rule check that treats an
    ;; explicit (unquote ...)/(unquote-splicing ...) value as "still a decl,
    ;; just a dynamic one" rather than mistaking it for a nested rule.

    (define (css-unquote? form)
      (and (pair? form) (eq? (car form) 'unquote)))

    (define (css-unquote-splicing? form)
      (and (pair? form) (eq? (car form) 'unquote-splicing)))

    (define (css-static? form)
      (cond
       ((css-unquote? form) #f)
       ((css-unquote-splicing? form) #f)
       ((pair? form) (and (css-static? (car form)) (css-static? (cdr form))))
       (else #t)))

    (define (css-render-to-string-list rules)
      (let ((port (open-output-string)))
        (css-render port rules)
        (get-output-string port)))

    ;; A decl at the SYNTAX level: exactly 2 elements, whose value is either
    ;; a plain atom or an explicit unquote/unquote-splicing marker -- a
    ;; nested rule's value position is a genuine pair, never one of those
    ;; two markers.
    (define (css-item-decl? item)
      (and (pair? (cdr item)) (null? (cddr item))
           (let ((v (cadr item)))
             (or (not (pair? v)) (css-unquote? v) (css-unquote-splicing? v)))))

    (define (css-unwrap-value value)
      (cond
       ((css-unquote? value) (cadr value))
       ((css-unquote-splicing? value)
        (error "css!: unquote-splicing not supported as a declaration value" value))
       (else (list 'quote value))))

    ;; Checks that every selector in `rule` -- its own, and any nested
    ;; rule's, at any depth -- is static; decl VALUES may still be dynamic,
    ;; only selector positions must be knowable at compile time to fold.
    (define (css-selectors-static? rule)
      (and (css-static? (car rule)) (css-item-selectors-static? (cdr rule))))

    (define (css-item-selectors-static? items)
      (cond
       ((null? items) #t)
       ((css-item-decl? (car items)) (css-item-selectors-static? (cdr items)))
       (else (and (css-selectors-static? (car items)) (css-item-selectors-static? (cdr items))))))

    (define (css-merge-pieces pieces)
      (cond
       ((null? pieces) '())
       ((null? (cdr pieces)) pieces)
       ((and (eq? (caar pieces) 'lit) (eq? (car (cadr pieces)) 'lit))
        (css-merge-pieces
         (cons (cons 'lit (string-append (cdar pieces) (cdr (cadr pieces)))) (cddr pieces))))
       (else (cons (car pieces) (css-merge-pieces (cdr pieces))))))

    (define (css-piece->stmt piece port-sym)
      (if (eq? (car piece) 'lit)
          (list 'write-string (cdr piece) port-sym)
          (cdr piece)))

    (define (css-pieces->body pieces port-sym)
      (map (lambda (p) (css-piece->stmt p port-sym)) pieces))

    ;; Folds one decl item: a static value becomes one lit chunk (rendered
    ;; via write-decl at expansion time); a dynamic value becomes a runtime
    ;; write-decl call.
    (define (css-fold-decl item port-sym)
      (if (css-static? item)
          (list (cons 'lit (let ((p (open-output-string))) (write-decl p item) (get-output-string p))))
          (list (cons 'code
                      (list 'write-decl port-sym
                            (list 'list (list 'quote (car item)) (css-unwrap-value (cadr item))))))))

    ;; Folds a rule whose own selector and every nested selector are already
    ;; known static (checked by the caller) -- only decl values may still
    ;; be dynamic. `selector` is the already-combined literal selector
    ;; (string or list of strings) for this rule.
    (define (css-fold-rule-items selector items port-sym)
      (let loop ((remaining items) (decls-rev '()) (nested-rev '()))
        (if (pair? remaining)
            (if (css-item-decl? (car remaining))
                (loop (cdr remaining) (cons (car remaining) decls-rev) nested-rev)
                (loop (cdr remaining) decls-rev (cons (car remaining) nested-rev)))
            (let* ((ordered-decls (reverse decls-rev))
                   (ordered-nested (reverse nested-rev))
                   (decl-pieces
                    (css-merge-pieces (apply append (map (lambda (d) (css-fold-decl d port-sym)) ordered-decls))))
                   (own-pieces
                    (if (pair? ordered-decls)
                        (append (list (cons 'lit (string-append (selector->string selector) " {\n")))
                                decl-pieces
                                (list (cons 'lit "}\n")))
                        '()))
                   (nested-pieces
                    (apply append
                           (map (lambda (n) (css-fold (cons (combine-selectors selector (car n)) (cdr n)) port-sym))
                                ordered-nested))))
              (css-merge-pieces (append own-pieces nested-pieces))))))

    ;; (css-fold rule port-sym) -> a list of pieces for one rule. `rule` is
    ;; raw macro-argument syntax, not evaluated data.
    (define (css-fold rule port-sym)
      (cond
       ((css-static? rule) (list (cons 'lit (css-render-to-string-list (list rule)))))
       ((css-unquote? rule) (list (cons 'code (list 'css-render port-sym (list 'list (cadr rule))))))
       ((css-unquote-splicing? rule) (list (cons 'code (list 'css-render port-sym (cadr rule)))))
       ((eq? (car rule) 'raw)
        ;; Dynamic raw content (rare) -- fall back to the runtime renderer,
        ;; rebuilding the original quasiquote form for just this rule.
        (list (cons 'code (list 'css-render port-sym (list 'list (list 'quasiquote rule))))))
       ((not (css-selectors-static? rule))
        ;; A dynamic selector somewhere, top-level or nested -- same
        ;; fallback (folding a rule whose own shape isn't fully known
        ;; statically isn't attempted).
        (list (cons 'code (list 'css-render port-sym (list 'list (list 'quasiquote rule))))))
       (else (css-fold-rule-items (car rule) (cdr rule) port-sym))))

    ;; (css-fold-rules rules port-sym) -> a list of pieces for a whole
    ;; stylesheet (a list of rules, or a single ,expr/,@expr standing in
    ;; for the whole thing).
    (define (css-fold-rules rules port-sym)
      (cond
       ((css-unquote? rules) (list (cons 'code (list 'css-render port-sym (list 'list (cadr rules))))))
       ((css-unquote-splicing? rules) (list (cons 'code (list 'css-render port-sym (cadr rules)))))
       ((null? rules) '())
       ((pair? rules) (css-merge-pieces (apply append (map (lambda (r) (css-fold r port-sym)) rules))))
       (else (error "css-fold-rules: invalid stylesheet" rules))))

    ;; A fixed (not gensym'd) port variable name -- see (creme html)'s
    ;; html! for why: defmacro transformer bodies always run against the
    ;; interpreter's single @global env, so gensym would need (creme
    ;; introspection) imported at every css! call site too.
    (defmacro css! (template)
      (let* ((port-sym '%css-port%)
             (inner (if (and (pair? template) (eq? (car template) 'quasiquote))
                        (cadr template)
                        template))
             (pieces (css-fold-rules inner port-sym)))
        (cond
         ((null? pieces) "")
         ((and (null? (cdr pieces)) (eq? (caar pieces) 'lit)) (cdar pieces))
         (else
          (list 'let (list (list port-sym (list 'open-output-string)))
                (cons 'begin (css-pieces->body pieces port-sym))
                (list 'get-output-string port-sym))))))

    ;; (css-write! port rules) -> the same folding as css!, but writing
    ;; directly into an already-open `port` instead of creating a fresh
    ;; one; returns unspecified, not a string.
    (defmacro css-write! (port template)
      (let* ((port-sym '%css-port%)
             (inner (if (and (pair? template) (eq? (car template) 'quasiquote))
                        (cadr template)
                        template))
             (pieces (css-fold-rules inner port-sym)))
        (list 'let (list (list port-sym port))
              (cons 'begin (css-pieces->body pieces port-sym)))))))
