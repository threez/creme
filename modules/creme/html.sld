;; ===========================================================================
;; (creme html): a Hiccup-style HTML5 builder, plus a table style
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme sxql)/(creme extra) use) rather than compiled into the interpreter
;; binary, since every export here is expressible in plain R7RS with no
;; opaque foreign object, stateful handle, or third-party Crystal library
;; involved — see modules/creme/extra.sld's own header comment for the same
;; rationale.
;;
;; A page is plain nested list data (a "node"), not a sequence of imperative
;; calls — closer to Clojure's Hiccup or Racket's x-expressions than to a
;; Crystal-style block DSL. This fits R7RS far better: no macro-hygiene
;; concerns (this project's syntax-rules is unhygienic), and building a page
;; is just ordinary list-building — map/quasiquote/if all work directly,
;; with no special sub-DSL to learn.
;;
;; node grammar:
;;   string                 -> HTML-escaped text
;;   number                 -> number->string, then escaped text
;;   #f                     -> nothing (so (and condition node) can be a child)
;;   '()                    -> nothing
;;   (raw string ...)       -> unescaped, concatenated verbatim (e.g. inline
;;                             <script>/<style> bodies)
;;   (tag . rest)           -> an element, `tag` a symbol; if (car rest) is
;;                             (@ (name value) ...) that's the attrs block,
;;                             else attrs default to '(); remaining items are
;;                             child nodes
;;   (node node ...)        -> a fragment: car is NOT a symbol, so this is a
;;                             sequence of nodes spliced in place — what lets
;;                             (map row items) work directly as a run of
;;                             children, e.g. (ul (@ (class "x")) ,@(map ...))
;;
;; attrs is a list of two-element (name value) lists — name a symbol or
;; string, value a string/number (escaped and quoted), #t (bare boolean
;; attribute, e.g. disabled), or #f (attribute omitted entirely).
;;
;; Void elements (area base br col embed hr img input link meta param source
;; track wbr) render self-closing with no children; giving one child nodes
;; is an error.
;;
;;   (html-escape s)                 -> s, HTML-escaped
;;   (html-render port node)         -> writes node's rendering into port
;;   (html->string node)             -> renders node against a fresh string
;;                                      port, returns the accumulated string
;;   (html! node)                    -> a defmacro, same contract as
;;                                      html->string but folds every part of
;;                                      `node` that's free of ,expr/,@expr
;;                                      into a plain string literal AT
;;                                      MACRO-EXPANSION TIME, leaving only
;;                                      the genuinely dynamic seams to
;;                                      render at runtime — use it wherever
;;                                      the node tree is written directly as
;;                                      a literal (quasiquoted) template at
;;                                      the call site, exactly like
;;                                      html->string is used today. Any
;;                                      script calling html! must itself
;;                                      (import (creme html)) directly (not
;;                                      just transitively via some other
;;                                      library) — a defmacro transformer
;;                                      body always runs against this
;;                                      interpreter's single shared @global
;;                                      env, not its defining library's own
;;                                      env, so the helper procedures html!
;;                                      calls while expanding must already
;;                                      be there, exactly as (creme sxql)'s
;;                                      sxql-select! requires sxql-run to be
;;                                      visible at its own call sites too
;;   (html-write! port node)         -> a defmacro, the same folding as
;;                                      html! but writing directly into an
;;                                      already-open `port` instead of
;;                                      creating a fresh one — for a
;;                                      caller that already has a port to
;;                                      write into (e.g. streaming an HTTP
;;                                      response body via (creme mux),
;;                                      instead of building the whole page
;;                                      as one string first); returns
;;                                      unspecified, not a string. Same
;;                                      @global-visibility requirement as
;;                                      html!
;;   (html-document->string title css body) -> a full <!DOCTYPE html>
;;                                      document string; body is a node;
;;                                      css is either a plain string
;;                                      (embedded verbatim) or a (creme css)
;;                                      rule list (serialized via
;;                                      css->string first)
;;   (html-document-write! port title css body) -> the same document as
;;                                      html-document->string, written
;;                                      directly into `port` instead of
;;                                      built as a string first — an
;;                                      ordinary procedure (title/css/body
;;                                      are runtime values either way,
;;                                      nothing here is folded at
;;                                      compile time)
;;   (html-tag port name attrs body-thunk)   — low-level: <name attrs...>,
;;                                      (body-thunk), </name>
;;   (html-void-tag port name attrs)         — low-level: <name attrs...>,
;;                                      no children/close
;;   (html-text port s)                      — low-level: writes s, escaped
;;
;; The html-tag/html-void-tag/html-text trio is the same port-based
;; recursive-builder primitive layer as before: every fragment is written
;; exactly once directly into one shared port (open-output-string wraps a
;; real growable buffer), so building a large/deeply-nested document is
;; O(total output size), not O(n^2) the way repeated string-append would be.
;; html-render/html->string are just a node-walking layer on top that calls
;; these same primitives — html-tag/html-void-tag/html-text are still
;; exported for advanced use (mixing hand-written port code with a rendered
;; subtree).
;;
;; Example:
;;
;;   (html->string
;;    `(html
;;      (head (title "Report"))
;;      (body
;;       (h1 (@ (class "title")) "Hello")
;;       (ul (@ (class "list"))
;;           ,@(map (lambda (x) `(li ,x)) '("a" "b" "c")))
;;       (input (@ (type "text") (disabled #t)))
;;       (br))))
;;
;; html-style is a (creme table) style function (see modules/creme/table.sld's
;; header comment for the style-function protocol) built from the above
;; primitives, producing a real <table> with <thead>/<tbody>/<tfoot> wrapping
;; whichever sections are present and <th> cells for header rows (vs. <td>
;; for body/footer rows) — genuine semantic markup, not just a plain-text
;; table with HTML tags glued on. This module has no code dependency on
;; (creme table) at all (html-style is just an ordinary procedure matching
;; that protocol by convention) — importing (creme table) too is only needed
;; to call table-style/table->string themselves:
;;
;;   (import (creme table) (creme html))
;;   (table->string rows aligns (table-style html-style 'header 1))
;;
;; Not auto-imported anywhere — every script that wants any of this must
;; (import (creme html)) explicitly, same as any other file-based library.
;; ===========================================================================

(define-library (creme html)
  (export html-document->string html-document-write! html-escape html-fold html-merge-pieces
          html-pieces->body html-render html-style html->string html-tag html-text html-void-tag
          html! html-write! write-dynamic-attr)
  (import (scheme base) (scheme write) (creme string) (creme css))
  (begin
    (define html-escape-table
      (list (cons #\& "&amp;") (cons #\< "&lt;") (cons #\> "&gt;") (cons #\" "&quot;") (cons #\' "&#39;")))

    ;; HTML-escaping for arbitrary text, safe to embed as either element
    ;; content (& < >) or an attribute value (" '), matching what standard
    ;; escapers do (e.g. Ruby's CGI.escapeHTML, Python's html.escape).
    ;; string-translate ((creme string), a native Crystal builtin) finds
    ;; and substitutes all five special characters in a single native pass
    ;; over s — replacing the previous 5-chained-string-replace
    ;; implementation, which rescanned/reallocated the whole string 5
    ;; times. (A hand-written Scheme char-by-char loop was tried in
    ;; between and measured SLOWER than the 5-chain despite being
    ;; algorithmically a single pass: each loop iteration runs through
    ;; this interpreter's own bytecode dispatch, and that per-character
    ;; interpretation overhead dwarfs the native string-copying cost the
    ;; 5-chain was paying — a single *native* pass, not a single
    ;; *interpreted* pass, is what actually wins here.)
    (define (html-escape s)
      (string-translate s html-escape-table))

    ;; ---- port-based builders ----------------------------------------------

    ;; attrs is a list of (name value) two-element lists; value #t writes a
    ;; bare boolean attribute (no ="..."), #f omits the attribute entirely.
    (define (write-attrs port attrs)
      (if (pair? attrs)
          (let* ((entry (car attrs))
                 (name (attr-name->string (car entry)))
                 (value (cadr entry)))
            (cond
             ((eq? value #f) #t)
             ((eq? value #t)
              (write-string " " port)
              (write-string name port))
             (else
              (write-string " " port)
              (write-string name port)
              (write-string "=\"" port)
              (write-string (html-escape (attr-value->string value)) port)
              (write-string "\"" port)))
            (write-attrs port (cdr attrs)))))

    (define (attr-name->string name)
      (if (symbol? name) (symbol->string name) name))

    (define (attr-value->string value)
      (if (string? value) value (number->string value)))

    ;; Writes one dynamic attribute directly (no attrs list ever built): #f
    ;; omits it, #t writes a bare boolean attribute, anything else writes
    ;; name="escaped-value". Used by html!'s/html-write!'s expansion for a
    ;; node's dynamic attrs entries, one call per entry — see the
    ;; compile-time template folding section below.
    (define (write-dynamic-attr port name value)
      (cond
       ((eq? value #f) #t)
       ((eq? value #t) (write-string " " port) (write-string name port))
       (else
        (write-string " " port)
        (write-string name port)
        (write-string "=\"" port)
        (write-string (html-escape (attr-value->string value)) port)
        (write-string "\"" port))))

    (define (write-open-tag port name attrs)
      (write-string "<" port)
      (write-string name port)
      (write-attrs port attrs)
      (write-string ">" port))

    ;; (html-tag port name attrs body-thunk) -> writes <name attrs...>, calls
    ;; (body-thunk) — expected to write its own content (text and/or nested
    ;; html-tag/html-void-tag/html-text calls) into this SAME port — then
    ;; writes </name>. The core recursive-builder primitive: no matter how
    ;; deep body-thunk's own nesting goes, every fragment is written exactly
    ;; once, directly into the one port shared by the whole call tree.
    (define (html-tag port name attrs body-thunk)
      (write-open-tag port name attrs)
      (body-thunk)
      (write-string "</" port)
      (write-string name port)
      (write-string ">" port))

    ;; (html-void-tag port name attrs) -> a self-closing/void element (meta,
    ;; br, hr, link, ...): <name attrs...>, no children, no closing tag.
    (define (html-void-tag port name attrs)
      (write-open-tag port name attrs))

    ;; (html-text port s) -> writes `s`, HTML-escaped, directly to `port`.
    (define (html-text port s)
      (write-string (html-escape s) port))

    ;; ---- node-walking renderer ---------------------------------------------

    (define void-elements
      '("area" "base" "br" "col" "embed" "hr" "img" "input" "link" "meta"
        "param" "source" "track" "wbr"))

    (define (void-element? name)
      (member name void-elements))

    (define (attrs-block? node)
      (and (pair? node) (eq? (car node) '@)))

    (define (render-children port children)
      (for-each (lambda (child) (html-render port child)) children))

    ;; (html-render port node) -> writes node's rendering directly into
    ;; `port`, recursing through the node grammar documented above.
    (define (html-render port node)
      (cond
       ((eq? node #f) #t)
       ((null? node) #t)
       ((string? node) (html-text port node))
       ((number? node) (html-text port (number->string node)))
       ((and (pair? node) (eq? (car node) 'raw))
        (write-string (apply string-append (cdr node)) port))
       ((and (pair? node) (symbol? (car node)))
        (let* ((name (symbol->string (car node)))
               (rest (cdr node))
               (has-attrs (and (pair? rest) (attrs-block? (car rest))))
               (attrs (if has-attrs (cdar rest) '()))
               (children (if has-attrs (cdr rest) rest)))
          (if (void-element? name)
              (begin
                (if (pair? children)
                    (error "html-render: void element cannot have children" name))
                (html-void-tag port name attrs))
              (html-tag port name attrs
                        (lambda () (render-children port children))))))
       ((pair? node) (render-children port node))
       (else (error "html-render: invalid node" node))))

    ;; (html->string node) -> renders node against a fresh string port,
    ;; returns the accumulated string.
    (define (html->string node)
      (let ((port (open-output-string)))
        (html-render port node)
        (get-output-string port)))

    ;; ---- compile-time template folding (html!) -----------------------------
    ;;
    ;; `html-fold` mirrors `html-render`'s own grammar dispatch exactly, but
    ;; at macro-expansion time and over raw, unevaluated syntax rather than
    ;; runtime data. It returns a list of "pieces", each either (lit . str)
    ;; — a precomputed string chunk — or (code . expr) — a runtime
    ;; expression that writes into the port itself when evaluated. Literal
    ;; syntax (no ,expr/,@expr anywhere inside) collapses to a single `lit`
    ;; piece by calling the real html-render directly on the raw syntax at
    ;; expansion time (valid because syntax free of variables is already
    ;; structurally identical to the data it would evaluate to).

    (define (html-unquote? form)
      (and (pair? form) (eq? (car form) 'unquote)))

    (define (html-unquote-splicing? form)
      (and (pair? form) (eq? (car form) 'unquote-splicing)))

    ;; #t iff a (raw ...) node's arguments are all directly foldable into
    ;; verbatim writes — each either a string literal or a plain (unquote
    ;; expr). Those are the shapes for which html-fold's raw branch below
    ;; can emit direct write-string calls instead of rebuilding the node and
    ;; dispatching through html-render at runtime. Anything else (a bare
    ;; symbol, a nested list, unquote-splicing) takes the safe html-render
    ;; fallback, so the fast path never changes behaviour for an odd shape.
    (define (html-raw-foldable? args)
      (and (pair? args)
           (let loop ((a args))
             (cond
              ((null? a) #t)
              ((html-unquote? (car a)) (loop (cdr a)))
              ((string? (car a)) (loop (cdr a)))
              (else #f)))))

    ;; #f the moment an (unquote ...)/(unquote-splicing ...) form is found
    ;; anywhere inside, recursively — #t otherwise (no nested-quasiquote
    ;; support: a documented limitation, consistent with this project's
    ;; already-unhygienic macro system; real templates don't nest backtick).
    (define (html-static? form)
      (cond
       ((html-unquote? form) #f)
       ((html-unquote-splicing? form) #f)
       ((pair? form) (and (html-static? (car form)) (html-static? (cdr form))))
       (else #t)))

    (define (html-render-to-string form)
      (let ((port (open-output-string)))
        (html-render port form)
        (get-output-string port)))

    ;; Merges consecutive (lit . str) pieces into one, so a run of static
    ;; children collapses to a single write-string call instead of many.
    (define (html-merge-pieces pieces)
      (cond
       ((null? pieces) '())
       ((null? (cdr pieces)) pieces)
       ((and (eq? (caar pieces) 'lit) (eq? (car (cadr pieces)) 'lit))
        (html-merge-pieces
         (cons (cons 'lit (string-append (cdar pieces) (cdr (cadr pieces)))) (cddr pieces))))
       (else (cons (car pieces) (html-merge-pieces (cdr pieces))))))

    (define (html-piece->stmt piece port-sym)
      (if (eq? (car piece) 'lit)
          (list 'write-string (cdr piece) port-sym)
          (cdr piece)))

    (define (html-pieces->body pieces port-sym)
      (map (lambda (p) (html-piece->stmt p port-sym)) pieces))

    ;; Attrs fold per ENTRY, not as one all-or-nothing block: a static
    ;; entry (name and value both known at expansion time) becomes one lit
    ;; chunk (the whole ` name="value"` fragment, pre-escaped); a dynamic
    ;; entry becomes one write-dynamic-attr call writing just that entry,
    ;; directly, at runtime — no attrs list is ever built (not even at
    ;; runtime) and no body-thunk closure is needed either, since the
    ;; open tag and children are now just more pieces in the same flat
    ;; sequence, unconditionally, for every node — dynamic attrs, dynamic
    ;; children, both, or neither.
    (define (html-attrs-splicing? attrs-form)
      (and attrs-form
           (let loop ((entries (cdr attrs-form)))
             (cond
              ((null? entries) #f)
              ((and (pair? (car entries)) (eq? (caar entries) 'unquote-splicing)) #t)
              (else (loop (cdr entries)))))))

    (define (html-unwrap-attr-value value)
      (cond
       ((html-unquote? value) (cadr value))
       ((html-unquote-splicing? value)
        (error "html!: unquote-splicing not supported as an attribute value" value))
       (else (list 'quote value))))

    (define (html-fold-attr-entry entry port-sym)
      (let* ((name-str (attr-name->string (car entry)))
             (value (cadr entry)))
        (if (html-static? value)
            (cond
             ((eq? value #f) '())
             ((eq? value #t) (list (cons 'lit (string-append " " name-str))))
             (else
              (list (cons 'lit
                          (string-append " " name-str "=\"" (html-escape (attr-value->string value)) "\"")))))
            (list (cons 'code
                        (list 'write-dynamic-attr port-sym name-str (html-unwrap-attr-value value)))))))

    (define (html-fold-attrs-pieces attrs-form port-sym)
      (if attrs-form
          (apply append (map (lambda (e) (html-fold-attr-entry e port-sym)) (cdr attrs-form)))
          '()))

    (define (html-fold-void-element tag-str attrs-form children port-sym)
      (if (pair? children)
          (error "html!: void element cannot have children" tag-str))
      (html-merge-pieces
       (append (list (cons 'lit (string-append "<" tag-str)))
               (html-fold-attrs-pieces attrs-form port-sym)
               (list (cons 'lit ">")))))

    (define (html-fold-container-element tag-str attrs-form children port-sym)
      (let ((child-pieces (html-merge-pieces
                            (apply append (map (lambda (c) (html-fold c port-sym)) children)))))
        (html-merge-pieces
         (append (list (cons 'lit (string-append "<" tag-str)))
                 (html-fold-attrs-pieces attrs-form port-sym)
                 (list (cons 'lit ">"))
                 child-pieces
                 (list (cons 'lit (string-append "</" tag-str ">")))))))

    (define (html-fold-element form port-sym)
      (let* ((tag-sym (car form))
             (tag-str (symbol->string tag-sym))
             (rest (cdr form))
             (has-attrs (and (pair? rest) (attrs-block? (car rest))))
             (attrs-form (if has-attrs (car rest) #f))
             (children (if has-attrs (cdr rest) rest)))
        (if (and has-attrs (html-attrs-splicing? attrs-form))
            ;; Rare/unsupported attrs shape (splicing a whole computed attrs
            ;; list): fall back to the plain runtime renderer for this one
            ;; node, by rebuilding the original quasiquote form around it —
            ;; always correct, just without folding for this node.
            (list (cons 'code (list 'html-render port-sym (list 'quasiquote form))))
            (if (void-element? tag-str)
                (html-fold-void-element tag-str attrs-form children port-sym)
                (html-fold-container-element tag-str attrs-form children port-sym)))))

    ;; (html-fold form port-sym) -> a list of pieces (see above), folding
    ;; `form` (raw macro-argument syntax, not evaluated data) recursively.
    (define (html-fold form port-sym)
      (cond
       ((html-static? form) (list (cons 'lit (html-render-to-string form))))
       ((html-unquote? form) (list (cons 'code (list 'html-render port-sym (cadr form)))))
       ((html-unquote-splicing? form) (list (cons 'code (list 'html-render port-sym (cadr form)))))
       ((and (pair? form) (eq? (car form) 'raw))
        ;; Dynamic raw content: fold each argument straight into a verbatim
        ;; write rather than rebuilding the node and dispatching through
        ;; html-render at runtime. `raw` writes its args verbatim (no
        ;; escaping), so a string-literal arg is a lit piece and an
        ;; ,expr arg is a direct (write-string expr port). This removes the
        ;; per-call quasiquote cons and html-render's own string-append copy
        ;; -- which matters when raw content is a large constant on a hot
        ;; path, e.g. an inline stylesheet spliced into every page as
        ;; (style (raw ,css)). Unusual shapes fall back to html-render.
        (if (html-raw-foldable? (cdr form))
            (html-merge-pieces
             (map (lambda (arg)
                    (if (html-unquote? arg)
                        (cons 'code (list 'write-string (cadr arg) port-sym))
                        (cons 'lit arg)))
                  (cdr form)))
            (list (cons 'code (list 'html-render port-sym (list 'quasiquote form))))))
       ((and (pair? form) (symbol? (car form)))
        (html-fold-element form port-sym))
       ((pair? form)
        ;; A fragment: a list of nodes with no tag wrapper, at least one
        ;; dynamic somewhere inside -- fold each element the same way a
        ;; container element folds its children.
        (html-merge-pieces (apply append (map (lambda (c) (html-fold c port-sym)) form))))
       (else (error "html-fold: unreachable" form))))

    ;; A fixed (not gensym'd) port variable name: defmacro transformer
    ;; bodies always run against the interpreter's single @global env (a
    ;; hard limitation of this project's defmacro, not library-scoped — see
    ;; the comment on html-fold's export above), so gensym would need
    ;; (creme introspection) imported at every html! call site too. Both
    ;; macro systems here are already unhygienic; an obscure fixed name
    ;; carries the same practical risk as any other unhygienic template
    ;; variable, documented rather than solved.
    (defmacro html! (template)
      (let* ((port-sym '%html-port%)
             (inner (if (and (pair? template) (eq? (car template) 'quasiquote))
                        (cadr template)
                        template))
             (pieces (html-merge-pieces (html-fold inner port-sym))))
        (if (and (pair? pieces) (null? (cdr pieces)) (eq? (caar pieces) 'lit))
            (cdar pieces)
            (list 'let (list (list port-sym (list 'open-output-string)))
                  (cons 'begin (html-pieces->body pieces port-sym))
                  (list 'get-output-string port-sym)))))

    ;; (html-write! port node) -> the same folding as html!, but writing
    ;; directly into an already-open `port` instead of creating a fresh
    ;; one; returns unspecified, not a string. `port` is bound once (via
    ;; the same fixed name html! uses) so an expression passed for it
    ;; isn't re-evaluated once per write.
    (defmacro html-write! (port template)
      (let* ((port-sym '%html-port%)
             (inner (if (and (pair? template) (eq? (car template) 'quasiquote))
                        (cadr template)
                        template))
             (pieces (html-merge-pieces (html-fold inner port-sym))))
        (list 'let (list (list port-sym port))
              (cons 'begin (html-pieces->body pieces port-sym)))))

    ;; (html-document->string title css body) -> a full <!DOCTYPE html>
    ;; document string: an escaped <title>, an inline <style> block holding
    ;; `css` verbatim (skipped if `css` is ""), and a <body> rendering `body`
    ;; (a node) — just one more render composition, not a separate mechanism
    ;; from the rest of this module.
    (define (html-document->string title css body)
      (let ((css-text (if (string? css) css (css->string css))))
        (html->string
         `((raw "<!DOCTYPE html>")
           (html
            (head
             (meta (@ (charset "utf-8")))
             (title ,title)
             ,(if (> (string-length css-text) 0) `(style (raw ,css-text)) #f))
            (body ,body))))))

    ;; (html-document-write! port title css body) -> the same document as
    ;; html-document->string, written directly into `port` instead of
    ;; built as a string first. An ordinary procedure, not a macro:
    ;; title/css/body are runtime values either way, so there's nothing
    ;; to fold at compile time here.
    (define (html-document-write! port title css body)
      (let ((css-text (if (string? css) css (css->string css))))
        (html-render
         port
         `((raw "<!DOCTYPE html>")
           (html
            (head
             (meta (@ (charset "utf-8")))
             (title ,title)
             ,(if (> (string-length css-text) 0) `(style (raw ,css-text)) #f))
            (body ,body))))))

    ;; ---- table style --------------------------------------------------------

    (define (html-row cell-tag cells)
      (cons 'tr (map (lambda (c) (list (string->symbol cell-tag) c)) cells)))

    ;; A (creme table) style function producing a real <table>, with
    ;; <thead>/<tbody>/<tfoot> wrapping whichever sections are present and
    ;; <th> cells for header rows (vs. <td> for body/footer rows). Ignores
    ;; `widths`/`aligns`: a browser lays out column widths and text alignment
    ;; itself.
    (define (html-style request cells widths aligns)
      (case request
        ((top) "<table>")
        ((bottom) "</table>")
        ((header-open) "<thead>")
        ((header-close) "</thead>")
        ((body-open) "<tbody>")
        ((body-close) "</tbody>")
        ((footer-open) "<tfoot>")
        ((footer-close) "</tfoot>")
        ((header-row) (html->string (html-row "th" cells)))
        ((row footer-row) (html->string (html-row "td" cells)))
        (else (error "table style: unknown request" request))))))
