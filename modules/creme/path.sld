;; ===========================================================================
;; (creme path): a macro-folded URL/file path builder
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme html)/(creme css)/(creme extra) use) rather than compiled into the
;; interpreter binary, since every export here is expressible in plain R7RS
;; with no opaque foreign object, stateful handle, or third-party Crystal
;; library involved — see modules/creme/extra.sld's own header comment for
;; the same rationale.
;;
;; Turns e.g. (string-append "/todos/" (number->string id) "/complete") into
;; (path 'todos id 'complete) — a segment written as a quoted symbol/string/
;; number literal ('todos, "todos", 42) is folded into the path's literal
;; skeleton AT MACRO-EXPANSION TIME (same folding approach as (creme html)'s
;; html!/(creme css)'s css!); a dynamic segment (a bare variable, an
;; expression) becomes a "~a" placeholder in a SINGLE (creme format) call
;; covering the whole path, e.g. (format #f "/todos/~a/complete" id) — one
;; native pass (format's own directive loop is a plain Crystal
;; String::Builder scan, not interpreted Scheme) stringifying each dynamic
;; argument via its native display_string, rather than a chain of
;; string-append calls each preceded by a Scheme-level symbol?/string?/
;; number? dispatch to decide how to stringify it. A path with no dynamic
;; segments at all skips format entirely and folds straight to one string
;; literal, same as before.
;;
;;   (path seg ...)      -> a defmacro: an absolute path string, "/" +
;;                          segments joined by "/" — (path) is "/"
;;   (rel-path seg ...)  -> the same, without the leading "/" —
;;                          (rel-path) is ""
;;
;; Example:
;;
;;   (path 'todos id 'complete)
;;   ;; folds to: (format #f "/todos/~a/complete" id)
;;   ;; => "/todos/42/complete"
;;
;; A literal segment whose text happens to contain "~" is escaped to "~~"
;; before being spliced into the format template, so it can't be misread as
;; a directive — (creme format)'s own escape for a literal tilde.
;;
;; Any script calling path/rel-path must itself (import (creme path)
;; (creme format)) directly — a defmacro transformer body always runs
;; against this interpreter's single shared @global env, not its defining
;; library's own env, so the helper procedures path/rel-path call while
;; expanding, AND any name their generated code refers to (format, for a
;; path with a dynamic segment), must already be visible at the call site,
;; exactly as (creme html)'s html!/(creme css)'s css! require of their own
;; callers (see those files' header comments for the full explanation). A
;; fully static path (no dynamic segments at all) never emits a call to
;; format, but the import is still required since whether a given path/
;; rel-path call needs it isn't visible until macro-expansion.
;;
;; Not auto-imported anywhere — every script that wants any of this must
;; (import (creme path)) explicitly, same as any other file-based library.
;; ===========================================================================

(define-library (creme path)
  (export path rel-path path-build path-segment->string
          dirname path-join)
  (import (scheme base) (creme string) (creme format))
  (begin
    ;; Plain 2-string filesystem-path helpers (distinct from (creme pathname)'s
    ;; POSIX/record-based decomposition): `dirname` returns everything up to the
    ;; last "/" ("" when there is none -- NOT "." like POSIX dirname), and
    ;; `path-join` joins a dir and a name with "/" (name alone when dir is "").
    ;; Shared by icecreme's own driver and the self-hosted compiler's own
    ;; include-relative resolution -- both previously kept private copies.
    (define (dirname path)
      (let loop ((i (- (string-length path) 1)))
        (cond
          ((< i 0) "")
          ((char=? (string-ref path i) #\/) (substring path 0 i))
          (else (loop (- i 1))))))

    (define (path-join dir name)
      (if (string=? dir "") name (string-append dir "/" name)))

    ;; (path-segment->string seg) -> seg stringified: a symbol via
    ;; symbol->string, a string as-is, a number via number->string. Only
    ;; used at macro-expansion time, on a segment already known to be a
    ;; compile-time literal — never appears in the generated runtime code.
    (define (path-segment->string seg)
      (cond
       ((symbol? seg) (symbol->string seg))
       ((string? seg) seg)
       ((number? seg) (number->string seg))
       (else (error "path: invalid segment" seg))))

    ;; A segment is a compile-time literal iff it's a self-evaluating
    ;; string/number, or a (quote datum) form (how 'todos reads) — anything
    ;; else (a bare variable, a procedure call) is a runtime segment.
    (define (path-literal? form)
      (or (string? form) (number? form)
          (and (pair? form) (eq? (car form) 'quote))))

    (define (path-literal-value form)
      (if (and (pair? form) (eq? (car form) 'quote)) (cadr form) form))

    ;; Folds one segment into either (lit . text) — its stringified,
    ;; ~-escaped text, known now — or (dyn . expr) — the raw runtime
    ;; expression to format via ~a later.
    (define (path-fold-segment seg)
      (if (path-literal? seg)
          (cons 'lit (string-replace (path-segment->string (path-literal-value seg)) "~" "~~"))
          (cons 'dyn seg)))

    (define (path-interleave-slashes pieces)
      (if (null? pieces)
          '()
          (cons (car pieces)
                (apply append (map (lambda (p) (list (cons 'lit "/") p)) (cdr pieces))))))

    ;; Walks the folded/separated pieces once, building the format template
    ;; string (literal text appended directly, a dynamic piece appending
    ;; "~a" and queuing its expression) — a bare string if nothing dynamic
    ;; turned up, else a (format #f template dyn ...) call.
    (define (path-emit pieces)
      (let loop ((ps pieces) (template "") (args '()))
        (cond
         ((null? ps)
          (if (null? args)
              template
              (append (list 'format #f template) (reverse args))))
         ((eq? (caar ps) 'lit) (loop (cdr ps) (string-append template (cdar ps)) args))
         (else (loop (cdr ps) (string-append template "~a") (cons (cdar ps) args))))))

    ;; Builds the final expansion: `leading` ("/" for path, "" for
    ;; rel-path) plus every segment, "/"-separated.
    (define (path-build leading segs)
      (let* ((seg-pieces (path-interleave-slashes (map path-fold-segment segs)))
             (all-pieces (if (> (string-length leading) 0) (cons (cons 'lit leading) seg-pieces) seg-pieces)))
        (path-emit all-pieces)))

    (defmacro path segs (path-build "/" segs))
    (defmacro rel-path segs (path-build "" segs))))
