;; ===========================================================================
;; (creme surf): a Sinatra-style declarative layer over (creme mux)
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme html)/(creme css)/(creme extra) use) rather than compiled into the
;; interpreter binary, since every export here is expressible in plain R7RS
;; on top of (creme mux)'s own primitives, with no opaque foreign object or
;; third-party Crystal library of its own involved — see modules/creme/
;; extra.sld's own header comment for the same rationale.
;;
;; (creme mux) is deliberately minimal: mux-get!/mux-post!/... take a raw
;; one-argument handler and require it to hand-build a response alist
;; itself, route-by-route. (creme surf) is sugar on top, never a
;; replacement — it still returns/consumes exactly the same request/response
;; alists (creme mux) does, so anything not covered here (streaming bodies,
;; custom headers, ...) still works by falling back to the lower-level
;; (creme mux) primitives directly, or via surf-response's escape hatch.
;;
;; ---- declaring routes --------------------------------------------------
;;
;;   (surf clause ...)              -> a fresh app (a mux-router; see
;;                                      surf-app below), with every clause
;;                                      registered as a route, e.g.:
;;
;;     (define router
;;       (surf
;;        (get "/" (request) (page-response))
;;        (post "/todos" (request)
;;          (add-todo! (cdr (assoc "title" (surf-form request))))
;;          (surf-redirect "/"))))
;;
;;                                      Each clause is (method path (req)
;;                                      body ...): `method` one of get/head/
;;                                      post/put/delete/patch (a bare,
;;                                      unquoted literal — not evaluated),
;;                                      `path` a (creme mux) radix path
;;                                      (":name" path params), `req` the
;;                                      name the request alist is bound to
;;                                      inside body. The clause's last body
;;                                      form's value is passed through
;;                                      surf-normalize-response (see below),
;;                                      so a handler can just return a
;;                                      string, or call surf-html/surf-
;;                                      redirect/surf-text/surf-response, or
;;                                      return a hand-built response alist —
;;                                      no (lambda (request) ...) wrapper
;;                                      and no manual response-alist
;;                                      plumbing required at the call site.
;;   (surf-app)                     -> a fresh app with no routes yet (a
;;                                      mux-router with surf-log-middleware
;;                                      already registered on it via
;;                                      mux-use! — see "logging" below) —
;;                                      for a script that wants to build its
;;                                      routing table up incrementally
;;                                      rather than as one surf form.
;;   (surf-route! app clause)       -> registers one more clause (same
;;                                      (method path (req) body ...) shape
;;                                      as above) onto an already-existing
;;                                      app value; `surf` itself is built
;;                                      out of repeated calls to this.
;;
;; `surf`/`surf-route!` are syntax-rules macros, not procedures — `method`
;; is matched as a literal identifier at the call site, never evaluated, so
;; it must be written bare (get, not 'get or "get"). Because this project's
;; syntax-rules is unhygienic (see the README's "Known caveats"/CLAUDE.md's
;; "Language dialect" section), the expansion of a clause refers directly to
;; `surf-normalize-response` by name in the *calling* script's own scope —
;; that's why it's exported below even though it reads like an internal
;; helper, the same reasoning (creme html)'s own header comment gives for
;; exporting html-fold/html-merge-pieces.
;;
;; ---- building a response --------------------------------------------------
;;
;; Every builder here returns the exact alist (creme mux) expects:
;;   ((status . N) (headers . (("name" . "value") ...)) (body . B))
;; `body` (B) is either a plain string, or a procedure of one argument (a
;; port) — passed straight through unchanged, exactly (creme mux)'s own
;; streaming-body contract (see mux.cr's header comment), so a handler that
;; wants to stream a large/dynamic body (e.g. via (creme html)'s
;; html-write!) works with these builders exactly as it would calling
;; (creme mux) directly.
;;
;;   (surf-response status headers body) -> the escape hatch: exactly the
;;                                      response alist above, for full
;;                                      manual control.
;;   (surf-text body)                -> 200, text/plain, `body` unchanged.
;;   (surf-text body status)         -> same, explicit status.
;;   (surf-html body)                -> 200, text/html. `body` is either a
;;                                      string/procedure (used as-is, e.g.
;;                                      the result of html->string/html!/
;;                                      html-write!) or a live (creme html)
;;                                      node, auto-rendered via html->string
;;                                      if so.
;;   (surf-html body status)         -> same, explicit status.
;;   (surf-redirect location)        -> 303 (See Other — the right code for
;;                                      redirect-after-POST), a Location
;;                                      header, empty body.
;;   (surf-redirect location status) -> same, explicit status.
;;   (surf-json body)                -> 200, application/json. `body` is
;;                                      either a string/procedure (used
;;                                      as-is, e.g. the result of
;;                                      json->string/json!/json-write!) or
;;                                      a live (creme json-builder) node,
;;                                      auto-rendered via json->string if
;;                                      so.
;;   (surf-json body status)         -> same, explicit status.
;;   (surf-normalize-response value) -> `value` unchanged if it's already a
;;                                      response alist (has a "status"
;;                                      entry); (surf-html value) if it's a
;;                                      plain string; errors otherwise. This
;;                                      is what every surf-registered route
;;                                      handler's return value passes
;;                                      through.
;;
;; ---- reading a request --------------------------------------------------
;;
;; All plain procedures over the request alist (creme mux) hands a handler
;; (method/path/path-params/headers/body — see mux.cr's header comment for
;; the exact shape):
;;
;;   (surf-method request)           -> the HTTP method string, e.g. "GET".
;;   (surf-path request)             -> the request path string.
;;   (surf-body request)             -> the raw request body string.
;;   (surf-header request name)      -> the named header's value, or #f if
;;                                      absent (vs. plain assoc, which
;;                                      errors on cdr of #f).
;;   (surf-path-param request name)  -> the named ":name" path-param value,
;;                                      or #f if absent.
;;   (surf-url-decode s)             -> `s`, application/x-www-form-
;;                                      urlencoded-decoded: "+" -> space,
;;                                      "%XX" -> the byte XX (hex).
;;   (surf-form request)             -> the request body, parsed as
;;                                      application/x-www-form-urlencoded
;;                                      into a real alist of every decoded
;;                                      field, e.g. "title=a+b&done=1" ->
;;                                      (("title" . "a b") ("done" . "1")).
;;   (surf-param request name)       -> the named value from path-params if
;;                                      present there, else from
;;                                      (surf-form request), else #f — the
;;                                      one accessor most handlers want,
;;                                      covering both a route's ":id" and a
;;                                      submitted form field by the same
;;                                      name.
;;
;; ---- content negotiation --------------------------------------------------
;;
;;   (surf-accept request clause ...) -> a match-inspired syntax-rules
;;                                      macro (see (creme match)'s own
;;                                      literal-else convention) for
;;                                      choosing a response by the
;;                                      request's Accept header:
;;
;;     (surf-accept request
;;       ("application/json" (surf-json (todos-json)))
;;       (else (page-response)))
;;
;;                                      Each clause's media-type is an
;;                                      ordinary string expression (not
;;                                      pattern-matched structurally —
;;                                      `else` is the only real literal),
;;                                      checked in order via
;;                                      surf-accepts? (below); the first
;;                                      matching clause's body runs. With
;;                                      no clause matching and no `else`,
;;                                      responds 406 (Not Acceptable) via
;;                                      surf-text — a real HTTP fallback,
;;                                      not an error.
;;   (surf-accepts? request media-type) -> #t if the request has no Accept
;;                                      header, the header contains
;;                                      "*/*", or the header contains
;;                                      media-type as a substring —
;;                                      deliberately simple substring
;;                                      matching, not full RFC 7231
;;                                      quality-value parsing (a known
;;                                      simplification, same spirit as
;;                                      surf-form's own documented
;;                                      omissions).
;;
;; Not covered: query-string parsing. (creme mux)'s request alist never
;; receives the request's raw query string from Crystal's HTTP::Request in
;; the first place (see mux.cr/request_to_scheme) — there's nothing in pure
;; Scheme to parse it out of, so adding query-param support here would
;; require a (creme mux) change first, out of scope for a Scheme-only
;; library like this one.
;;
;; ---- logging --------------------------------------------------------------
;;
;;   (surf-log-middleware request next) -> the default logging middleware,
;;                                      registered automatically by
;;                                      surf-app (and so by surf too, which
;;                                      is built out of surf-app) via
;;                                      (creme mux)'s own mux-use! — every
;;                                      request through a surf-built app
;;                                      logs one line, "METHOD /path ->
;;                                      status (Nms)", to
;;                                      (current-output-port) once
;;                                      handling finishes. Exported so a
;;                                      script can also register it
;;                                      manually on a router built via
;;                                      bare (creme mux) (mux-router)
;;                                      instead of surf-app, or compose it
;;                                      alongside its own middleware.
;;
;; Not auto-imported anywhere — every script that wants any of this must
;; (import (creme surf)) explicitly, same as any other file-based library.
;; ===========================================================================

(define-library (creme surf)
  (export surf surf-app surf-route! surf-normalize-response
          surf-response surf-text surf-html surf-redirect surf-json
          surf-method surf-path surf-body surf-header surf-path-param
          surf-url-decode surf-form surf-param
          surf-accept surf-accepts?
          surf-log-middleware)
  (import (scheme base) (scheme write) (creme mux) (creme html) (creme json-builder) (creme string) (creme time))
  (begin
    ;; ---- routing --------------------------------------------------------

    ;; (creme time)'s current-time is wall-clock float seconds -- good
    ;; enough for a request log, no need for a true monotonic clock here.
    (define (surf-log-middleware request next)
      (let* ((start (current-time))
             (status (next))
             (elapsed-ms (exact (round (* 1000 (time-difference (current-time) start))))))
        (write-string
         (string-append (surf-method request) " " (surf-path request) " -> "
                         (number->string status) " (" (number->string elapsed-ms) "ms)\n")
         (current-output-port))
        status))

    (define (surf-app)
      (let ((app (mux-router)))
        (mux-use! app surf-log-middleware)
        app))

    (define-syntax surf-route!
      (syntax-rules (get head post put delete patch)
        ((_ app (get path (req) body ...))
         (mux-get! app path (lambda (req) (surf-normalize-response (begin body ...)))))
        ((_ app (head path (req) body ...))
         (mux-head! app path (lambda (req) (surf-normalize-response (begin body ...)))))
        ((_ app (post path (req) body ...))
         (mux-post! app path (lambda (req) (surf-normalize-response (begin body ...)))))
        ((_ app (put path (req) body ...))
         (mux-put! app path (lambda (req) (surf-normalize-response (begin body ...)))))
        ((_ app (delete path (req) body ...))
         (mux-delete! app path (lambda (req) (surf-normalize-response (begin body ...)))))
        ((_ app (patch path (req) body ...))
         (mux-patch! app path (lambda (req) (surf-normalize-response (begin body ...)))))))

    (define-syntax surf
      (syntax-rules ()
        ((_ clause ...)
         (let ((app (surf-app)))
           (surf-route! app clause) ...
           app))))

    ;; ---- responses --------------------------------------------------------

    (define (surf-response status headers body)
      (list (cons "status" status) (cons "headers" headers) (cons "body" body)))

    (define (surf-text body . opt)
      (surf-response (if (pair? opt) (car opt) 200)
                     (list (cons "content-type" "text/plain"))
                     body))

    (define (surf-html body . opt)
      (surf-response (if (pair? opt) (car opt) 200)
                     (list (cons "content-type" "text/html"))
                     (if (or (string? body) (procedure? body)) body (html->string body))))

    (define (surf-redirect location . opt)
      (surf-response (if (pair? opt) (car opt) 303)
                     (list (cons "Location" location))
                     ""))

    (define (surf-json body . opt)
      (surf-response (if (pair? opt) (car opt) 200)
                     (list (cons "content-type" "application/json"))
                     (if (or (string? body) (procedure? body)) body (json->string body))))

    ;; #f the moment `v` isn't shaped like a response alist: a (name . value)
    ;; pair list with a "status" entry somewhere in it.
    (define (surf-response? v)
      (and (pair? v)
           (let loop ((entries v))
             (cond
              ((null? entries) #f)
              ((and (pair? (car entries)) (equal? (caar entries) "status")) #t)
              (else (loop (cdr entries)))))))

    (define (surf-normalize-response value)
      (cond
       ((surf-response? value) value)
       ((string? value) (surf-html value))
       (else (error "surf: handler returned an unsupported value (expected a response alist, a string, or the result of surf-response/surf-text/surf-html/surf-redirect)" value))))

    ;; ---- requests -----------------------------------------------------------

    (define (surf-alist-ref alist key)
      (let ((entry (assoc key alist)))
        (if entry (cdr entry) #f)))

    (define (surf-method request) (cdr (assoc "method" request)))
    (define (surf-path request) (cdr (assoc "path" request)))
    (define (surf-body request) (cdr (assoc "body" request)))

    (define (surf-header request name)
      (surf-alist-ref (cdr (assoc "headers" request)) name))

    (define (surf-path-param request name)
      (surf-alist-ref (cdr (assoc "path-params" request)) name))

    (define (surf-url-decode s)
      (let loop ((i 0) (acc '()))
        (cond
         ((>= i (string-length s)) (list->string (reverse acc)))
         ((char=? (string-ref s i) #\+) (loop (+ i 1) (cons #\space acc)))
         ((and (char=? (string-ref s i) #\%) (< (+ i 2) (string-length s)))
          (loop (+ i 3) (cons (integer->char (string->number (substring s (+ i 1) (+ i 3)) 16)) acc)))
         (else (loop (+ i 1) (cons (string-ref s i) acc))))))

    (define (surf-form-field->pair field)
      (let ((eq-pos (string-index-of field "=")))
        (if eq-pos
            (cons (surf-url-decode (substring field 0 eq-pos))
                  (surf-url-decode (substring field (+ eq-pos 1) (string-length field))))
            (cons (surf-url-decode field) ""))))

    (define (surf-form request)
      (let ((body (surf-body request)))
        (if (= (string-length body) 0)
            '()
            (map surf-form-field->pair (string-split body "&")))))

    (define (surf-param request name)
      (let ((path-value (surf-path-param request name)))
        (if path-value
            path-value
            (surf-alist-ref (surf-form request) name))))

    ;; ---- content negotiation ------------------------------------------------

    (define (surf-accepts? request media-type)
      (let ((accept (surf-header request "Accept")))
        (or (not accept) (string-contains? accept "*/*") (string-contains? accept media-type))))

    (define-syntax surf-accept
      (syntax-rules (else)
        ((_ req (else body ...)) (begin body ...))
        ((_ req (media-type body ...) rest ...)
         (if (surf-accepts? req media-type)
             (begin body ...)
             (surf-accept req rest ...)))
        ((_ req) (surf-text "Not Acceptable" 406))))))
