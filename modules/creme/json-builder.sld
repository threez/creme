;; ===========================================================================
;; (creme json-builder): a macro-folded JSON template builder
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme html)/(creme css)/(creme path) use) rather than compiled into the
;; interpreter binary, since every export here is expressible in plain R7RS
;; with no opaque foreign object, stateful handle, or third-party Crystal
;; library involved — see modules/creme/extra.sld's own header comment for
;; the same rationale. This is a DIFFERENT concern from the compiled
;; (creme json) library: that one is json-read/json-write, parsing/
;; stringifying arbitrary already-built Scheme data (e.g. reading a JSON
;; config file); this one is a template builder for constructing JSON output
;; fast, exactly (creme html)'s own relationship to raw string
;; concatenation. This library does not import/depend on (creme json) at
;; all — a defmacro's transformer body only ever sees the interpreter's
;; single shared @global env (not its defining library's own env), so
;; anything the fold machinery below calls while expanding must already be
;; visible there; depending on another library for that would mean every
;; script using json!/json-write! would also need that other library
;; imported first, purely as an expansion-time implementation detail. Kept
;; fully self-contained instead, the same way (creme html)'s html-escape
;; doesn't depend on any other escaping library either.
;;
;; node grammar (explicit tags, not (creme json)'s own alist-vs-array SHAPE
;; heuristic — deliberately avoided here so there's no ambiguity to reason
;; about at macro-expansion time, at the cost of one explicit tag):
;;
;;   string                 -> a JSON string, escaped + quoted
;;   number                 -> a JSON number (an exact integer or an
;;                             inexact real only — a rational or complex
;;                             value errors, since neither has valid JSON
;;                             number syntax)
;;   #t / #f                -> true / false
;;   'null                  -> null
;;   (object (key val) ...) -> {"key":val,...} — key a symbol or string,
;;                             always a literal (never ,expr — object keys
;;                             are known statically in every realistic use,
;;                             the same assumption (creme dao)'s kvs/
;;                             (creme sxql)'s set= already make about
;;                             column names)
;;   (array item ...)       -> [item,...]
;;   (raw string-expr)      -> string-expr embedded verbatim, unescaped and
;;                             unquoted (e.g. splicing in another json!
;;                             call's already-built string) — the same
;;                             escape hatch (creme html)'s (raw ...)
;;                             provides
;;
;; No special ,@ array/object-splicing machinery is needed or provided: a
;; variable-length array is built the same way a variable-length HTML list
;; already is elsewhere in this project — render each element independently
;; to its own string, string-join them with "," (an ordinary runtime
;; operation, (creme string)'s string-join), and splice the joined blob in
;; as one (array (raw joined)) item. This keeps the fold machinery exactly
;; as simple as (creme html)'s own (no separator bookkeeping at
;; expansion time).
;;
;;   (json-escape s)          -> s, as a quoted, escaped JSON string
;;                               literal (handles ", \, and control
;;                               characters, including a generic \u00XX
;;                               fallback for any character below U+0020,
;;                               not just the common named escapes)
;;   (json-render port node)  -> writes node's rendering into port
;;   (json->string node)      -> renders node against a fresh string port,
;;                               returns the accumulated string
;;   (json! node)             -> a defmacro, same contract as json->string
;;                               but folds every part of `node` that's free
;;                               of ,expr into a plain string literal AT
;;                               MACRO-EXPANSION TIME, leaving only the
;;                               genuinely dynamic seams to render at
;;                               runtime — same fold approach as (creme
;;                               html)'s html!. Any script calling json!
;;                               must itself (import (creme json-builder))
;;                               directly (not just transitively via some
;;                               other library) — a defmacro transformer
;;                               body always runs against this
;;                               interpreter's single shared @global env,
;;                               not its defining library's own env, so the
;;                               helper procedures json! calls while
;;                               expanding must already be there, exactly
;;                               as (creme html)'s html!/(creme sxql)'s
;;                               sxql-select! require of their own callers
;;   (json-write! port node)  -> a defmacro, the same folding as json! but
;;                               writing directly into an already-open
;;                               `port` instead of creating a fresh one —
;;                               for streaming a JSON response body (e.g.
;;                               via (creme mux)); returns unspecified, not
;;                               a string. Same @global-visibility
;;                               requirement as json!
;;   (json-array-write! port proc lst) -> writes a JSON array directly into
;;                               `port`: "[", then for each element of
;;                               `lst` calls (proc port elt) -- expected to
;;                               write that element's own JSON rendering
;;                               directly into `port` itself (typically via
;;                               json-write!), separated by ",", then "]".
;;                               NOT a macro, same reason json-write! itself
;;                               isn't one: `lst` is genuinely dynamic (e.g.
;;                               every row a (creme dao) query returns), so
;;                               there is no fixed set of array items for
;;                               json!'s compile-time fold to see. The
;;                               port-threaded counterpart to json-render/
;;                               json->string's node-walking: no per-element
;;                               node or string is ever materialized, so
;;                               streaming a large array into an HTTP
;;                               response port (e.g. via (creme mux)) is
;;                               O(total output size) with no intermediate
;;                               allocation.
;;
;; Example:
;;
;;   (json! `(object (id 1) (title ,title) (done #f)
;;                    (tags (array "a" "b" ,extra-tag))))
;;
;; Not auto-imported anywhere — every script that wants any of this must
;; (import (creme json-builder)) explicitly, same as any other file-based
;; library.
;; ===========================================================================

(define-library (creme json-builder)
  (export json-escape json-render json->string json-fold json-merge-pieces
          json-pieces->body json! json-write! json-array-write!)
  (import (scheme base) (scheme write) (creme string))
  (begin
    ;; Every character JSON needs escaped (control codes 0x00-0x1F, plus "
    ;; and \) is a small, fully enumerable, static set, so -- exactly like
    ;; (creme html)'s own html-escape-table (see html.sld's header comment
    ;; for the measured char-by-char-Scheme-loop-vs-native-pass rationale
    ;; this mirrors) -- the whole substitution table is built ONCE here,
    ;; rather than re-decided per character on every json-escape call. The
    ;; three 2-char escapes JSON singles out for readability (\n \t \r)
    ;; override the generic \u00XX form for their own codes; every other
    ;; control character gets \u00XX.
    (define json-escape-table
      (let loop ((code 0) (acc (list (cons #\" "\\\"") (cons #\\ "\\\\"))))
        (if (> code 31)
            acc
            (loop (+ code 1)
                  (cons (cons (integer->char code)
                              (cond
                               ((= code 10) "\\n")
                               ((= code 9) "\\t")
                               ((= code 13) "\\r")
                               (else
                                (let* ((hex (number->string code 16))
                                       (padded (string-append (make-string (- 4 (string-length hex)) #\0) hex)))
                                  (string-append "\\u" padded)))))
                        acc)))))

    ;; (json-escape s) -> s as a quoted, escaped JSON string literal, every
    ;; substitution found in a SINGLE native pass over s (string-translate,
    ;; (creme string)) rather than a per-character Scheme loop -- see
    ;; json-escape-table's own comment above.
    (define (json-escape s)
      (string-append "\"" (string-translate s json-escape-table) "\""))

    (define (json-key->string key)
      (if (symbol? key) (symbol->string key) key))

    (define (json-number? v)
      (and (number? v) (real? v) (or (exact-integer? v) (inexact? v))))

    ;; ---- port-based recursive renderer -------------------------------------

    (define (json-render-object port pairs)
      (write-string "{" port)
      (let loop ((pairs pairs) (first #t))
        (if (pair? pairs)
            (let ((entry (car pairs)))
              (if (not first) (write-string "," port))
              (write-string (json-escape (json-key->string (car entry))) port)
              (write-string ":" port)
              (json-render port (cadr entry))
              (loop (cdr pairs) #f))))
      (write-string "}" port))

    (define (json-render-array port items)
      (write-string "[" port)
      (let loop ((items items) (first #t))
        (if (pair? items)
            (begin
              (if (not first) (write-string "," port))
              (json-render port (car items))
              (loop (cdr items) #f))))
      (write-string "]" port))

    ;; (json-render port node) -> writes node's rendering directly into
    ;; `port`, recursing through the node grammar documented above.
    (define (json-render port node)
      (cond
       ((eq? node 'null) (write-string "null" port))
       ((eq? node #t) (write-string "true" port))
       ((eq? node #f) (write-string "false" port))
       ((string? node) (write-string (json-escape node) port))
       ((json-number? node) (write-string (number->string node) port))
       ((and (pair? node) (eq? (car node) 'raw)) (write-string (cadr node) port))
       ((and (pair? node) (eq? (car node) 'object)) (json-render-object port (cdr node)))
       ((and (pair? node) (eq? (car node) 'array)) (json-render-array port (cdr node)))
       (else (error "json-render: invalid node" node))))

    ;; (json->string node) -> renders node against a fresh string port,
    ;; returns the accumulated string.
    (define (json->string node)
      (let ((port (open-output-string)))
        (json-render port node)
        (get-output-string port)))

    ;; (json-array-write! port proc lst) -> writes a JSON array directly
    ;; into `port`, calling (proc port elt) for each element's own write --
    ;; see the header comment above for the full contract/rationale.
    (define (json-array-write! port proc lst)
      (write-string "[" port)
      (let loop ((lst lst) (first #t))
        (if (pair? lst)
            (begin
              (if (not first) (write-string "," port))
              (proc port (car lst))
              (loop (cdr lst) #f))))
      (write-string "]" port))

    ;; ---- compile-time template folding (json!) -----------------------------

    (define (json-unquote? form)
      (and (pair? form) (eq? (car form) 'unquote)))

    ;; #f the moment an (unquote ...) form is found anywhere inside,
    ;; recursively — #t otherwise (no unquote-splicing support at all, per
    ;; this library's own header comment: variable-length collections are
    ;; built with string-join + (raw ...) instead).
    (define (json-static? form)
      (cond
       ((json-unquote? form) #f)
       ((pair? form) (and (json-static? (car form)) (json-static? (cdr form))))
       (else #t)))

    (define (json-render-to-string form)
      (let ((port (open-output-string)))
        (json-render port form)
        (get-output-string port)))

    ;; Merges consecutive (lit . str) pieces into one, so a run of static
    ;; entries collapses to a single write-string call instead of many.
    (define (json-merge-pieces pieces)
      (cond
       ((null? pieces) '())
       ((null? (cdr pieces)) pieces)
       ((and (eq? (caar pieces) 'lit) (eq? (car (cadr pieces)) 'lit))
        (json-merge-pieces
         (cons (cons 'lit (string-append (cdar pieces) (cdr (cadr pieces)))) (cddr pieces))))
       (else (cons (car pieces) (json-merge-pieces (cdr pieces))))))

    (define (json-piece->stmt piece port-sym)
      (if (eq? (car piece) 'lit)
          (list 'write-string (cdr piece) port-sym)
          (cdr piece)))

    (define (json-pieces->body pieces port-sym)
      (map (lambda (p) (json-piece->stmt p port-sym)) pieces))

    ;; Joins a list of per-element piece-lists with a literal "," piece
    ;; between them, flattening to one piece list.
    (define (json-join-pieces piece-lists)
      (cond
       ((null? piece-lists) '())
       ((null? (cdr piece-lists)) (car piece-lists))
       (else (append (car piece-lists) (list (cons 'lit ",")) (json-join-pieces (cdr piece-lists))))))

    (define (json-fold-object pairs port-sym)
      (let* ((pair-pieces
              (map (lambda (entry)
                     (cons (cons 'lit (string-append (json-escape (json-key->string (car entry))) ":"))
                           (json-fold (cadr entry) port-sym)))
                   pairs)))
        (json-merge-pieces
         (append (list (cons 'lit "{")) (json-join-pieces pair-pieces) (list (cons 'lit "}"))))))

    (define (json-fold-array items port-sym)
      (json-merge-pieces
       (append (list (cons 'lit "["))
               (json-join-pieces (map (lambda (item) (json-fold item port-sym)) items))
               (list (cons 'lit "]")))))

    ;; (json-fold form port-sym) -> a list of pieces (each (lit . str) or
    ;; (code . expr), same shape/spirit as (creme html)'s html-fold),
    ;; folding `form` (raw macro-argument syntax, not evaluated data)
    ;; recursively.
    (define (json-fold form port-sym)
      (cond
       ((json-static? form) (list (cons 'lit (json-render-to-string form))))
       ((json-unquote? form) (list (cons 'code (list 'json-render port-sym (cadr form)))))
       ((and (pair? form) (eq? (car form) 'raw))
        ;; Dynamic raw content -- same safe fallback as unquote.
        (list (cons 'code (list 'json-render port-sym (list 'quasiquote form)))))
       ((and (pair? form) (eq? (car form) 'object)) (json-fold-object (cdr form) port-sym))
       ((and (pair? form) (eq? (car form) 'array)) (json-fold-array (cdr form) port-sym))
       (else (error "json-fold: invalid node" form))))

    ;; A fixed (not gensym'd) port variable name: same rationale (creme
    ;; html)'s html!/(creme path)'s path give for their own fixed
    ;; %html-port%/%path-port% names -- a defmacro transformer body always
    ;; runs against this interpreter's single shared @global env, so
    ;; gensym would need (creme introspection) imported at every json!
    ;; call site too.
    (defmacro json! (template)
      (let* ((port-sym '%json-port%)
             (inner (if (and (pair? template) (eq? (car template) 'quasiquote))
                        (cadr template)
                        template))
             (pieces (json-merge-pieces (json-fold inner port-sym))))
        (if (and (pair? pieces) (null? (cdr pieces)) (eq? (caar pieces) 'lit))
            (cdar pieces)
            (list 'let (list (list port-sym (list 'open-output-string)))
                  (cons 'begin (json-pieces->body pieces port-sym))
                  (list 'get-output-string port-sym)))))

    ;; (json-write! port node) -> the same folding as json!, but writing
    ;; directly into an already-open `port` instead of creating a fresh
    ;; one; returns unspecified, not a string.
    (defmacro json-write! (port template)
      (let* ((port-sym '%json-port%)
             (inner (if (and (pair? template) (eq? (car template) 'quasiquote))
                        (cadr template)
                        template))
             (pieces (json-merge-pieces (json-fold inner port-sym))))
        (list 'let (list (list port-sym port))
              (cons 'begin (json-pieces->body pieces port-sym)))))))
