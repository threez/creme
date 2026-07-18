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
;;        (get ("") (request) (page-response))
;;        (post ("todos") (request)
;;          (add-todo! (cdr (assoc "title" (surf-form request))))
;;          (surf-redirect "/"))
;;        (at ("todos" (id integer))
;;          (post ("complete") (request)
;;            (toggle-todo! id)
;;            (surf-redirect "/"))
;;          (post ("delete") (request)
;;            (todo-delete! id)
;;            (surf-redirect "/")))))
;;
;;                                      A clause is either a leaf route,
;;                                      (method (segment ...) (req name
;;                                      ...) body ...), or a group, (at
;;                                      (segment ...) clause ...) -- groups
;;                                      nest to any depth, each one's own
;;                                      segments prepended onto its
;;                                      children's, so a shared path prefix
;;                                      (here "todos"/:id) is written once
;;                                      no matter how many methods/sub-
;;                                      paths hang off it. `method` one of
;;                                      get/head/post/put/delete/patch (a
;;                                      bare, unquoted literal — not
;;                                      evaluated).
;;
;;                                      Each `segment` is either a literal
;;                                      path piece (an ordinary string,
;;                                      e.g. "todos", or "" for the root)
;;                                      or a capturing (name kind) pair —
;;                                      kind one of:
;;                                        integer -> string->number the
;;                                                   segment, requiring
;;                                                   integer? on the
;;                                                   result (so "3.14"
;;                                                   fails)
;;                                        float   -> string->number the
;;                                                   segment, accepting
;;                                                   any real number,
;;                                                   whole or fractional
;;                                        text    -> the raw segment
;;                                                   string, unparsed,
;;                                                   unvalidated
;;                                      A capturing segment's `name` is
;;                                      auto-bound (as the parsed value)
;;                                      for every handler nested under it,
;;                                      without needing to mention it again
;;                                      in that handler's own (req name
;;                                      ...) list -- the same guarantee
;;                                      Racket's dispatch-rules gets from a
;;                                      typed integer-arg path-segment
;;                                      matcher: for integer/float, a
;;                                      segment that's absent or doesn't
;;                                      parse as the requested kind
;;                                      responds 404 instead of running any
;;                                      handler nested under it, so a
;;                                      malformed ":id" never reaches
;;                                      handler code at all. A second
;;                                      position that's none of
;;                                      integer/float/text (a typo, or an
;;                                      unimplemented kind) raises a clear
;;                                      error rather than silently
;;                                      miscompiling. All of this --
;;                                      segment-list-to-path-string,
;;                                      segment-to-bound-name, group
;;                                      nesting -- is ordinary compile-
;;                                      time-only macro sugar (macros are
;;                                      fully expanded away at analyze
;;                                      time, before the compiler/VM ever
;;                                      run): the mux path string each
;;                                      route ultimately registers
;;                                      under, and the string->number/
;;                                      integer?/real? checks each typed
;;                                      segment does, are built once, at
;;                                      router-construction time (when
;;                                      `surf`/`at` runs), not per request
;;                                      -- no extra runtime dispatch
;;                                      machinery of its own beyond that
;;                                      one-time cost.
;;
;;                                      A leaf's own (req name ...) list
;;                                      works exactly as before for names
;;                                      NOT already bound by an enclosing
;;                                      group's captured segments -- most
;;                                      commonly a submitted form field,
;;                                      e.g. (post ("todos") (request
;;                                      title) ...) auto-binds `title` to
;;                                      (surf-param req "title"). A name
;;                                      here can also be plain (bound to
;;                                      the raw surf-param value, or #f if
;;                                      absent) or typed (name integer)/
;;                                      (name float) (same guard/404
;;                                      semantics as a captured path
;;                                      segment). The clause's last body
;;                                      form's value is passed through
;;                                      surf-normalize-response (see
;;                                      below), so a handler can just
;;                                      return a string, or call surf-
;;                                      html/surf-redirect/surf-text/surf-
;;                                      response, or return a hand-built
;;                                      response alist — no (lambda
;;                                      (request) ...) wrapper and no
;;                                      manual response-alist plumbing
;;                                      required at the call site.
;;   (surf-app)                     -> a fresh app with no routes yet (a
;;                                      mux-router with surf-log-middleware
;;                                      already registered on it via
;;                                      mux-use! — see "logging" below) —
;;                                      for a script that wants to build its
;;                                      routing table up incrementally
;;                                      rather than as one surf form.
;;   (surf-route! app clause)       -> registers one more clause (same
;;                                      leaf-or-group shape as above) onto
;;                                      an already-existing app value;
;;                                      `surf` itself is built out of
;;                                      repeated calls to this.
;;
;; `surf`/`surf-route!`/`at` are syntax-rules macros, not procedures —
;; `method` is matched as a literal identifier at the call site, never
;; evaluated, so it must be written bare (get, not 'get or "get"). Because
;; this project's syntax-rules is unhygienic (see the README's "Known
;; caveats" section), the expansion of a clause refers directly to several
;; helper names by identifier in the *calling* script's own scope — that's
;; why surf-normalize-response, surf-bind-params, surf-bind-path-segments,
;; and surf-clauses are exported
;; below even though they read like internal helpers, the same reasoning
;; (creme html)'s own header comment gives for exporting html-fold/html-
;; merge-pieces.
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
;;   (surf-remote-addr request)      -> the client's address, e.g.
;;                                      "1.2.3.4:5678" ("host:port", exactly
;;                                      Crystal's Socket::Address#to_s — no
;;                                      further parsing here).
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
;;                                      logs one line, "client-addr METHOD
;;                                      /path -> status (Nms)", to
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
  (export surf surf-app surf-route! surf-clauses surf-clause surf-register
          surf-path-string surf-join-segments surf-segment-literal
          surf-bind-path-segments surf-bind-params surf-normalize-response
          surf-response surf-text surf-html surf-redirect surf-json
          surf-method surf-path surf-body surf-remote-addr surf-header surf-path-param
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
         (string-append (surf-remote-addr request) " " (surf-method request) " " (surf-path request) " -> "
                         (number->string status) " (" (number->string elapsed-ms) "ms)\n")
         (current-output-port))
        status))

    (define (surf-app)
      (let ((app (mux-router)))
        (mux-use! app surf-log-middleware)
        app))

    ;; A clause's binding form is (req name ...) -- req is the request alist
    ;; as always, and each extra name (typically a route's own ":name" path
    ;; param, e.g. "/todos/:id/complete"'s id) is bound to (surf-param req
    ;; "name") before the body runs, so a handler never has to write out
    ;; (surf-param request "id") itself. `(symbol->string 'name)` rather
    ;; than a string literal since this project's syntax-rules can't
    ;; stringify an identifier at expansion time -- 'name after substitution
    ;; is a quoted symbol spelled exactly like the bound name, so this is
    ;; ordinary runtime code the macro emits, not a macro-time computation.
    ;; A name that isn't actually present (not a path param, no matching
    ;; form field) is simply bound to #f, same as calling surf-param by hand.
    ;;
    ;; A name can instead be written (name integer) or (name float) --
    ;; surf-bind-params peels the binding-spec list off one at a time (so
    ;; a clause can mix plain names and typed ones freely), and for a
    ;; typed spec parses the surf-param value as a number, short-circuiting
    ;; the whole clause to a 404 (rather than running body at all) if it's
    ;; absent or doesn't parse as the requested kind -- see this file's own
    ;; header comment for the rationale. `integer` requires the parsed
    ;; value to satisfy integer? (so "3.14" is rejected, not silently
    ;; truncated/accepted); `float` accepts any real number, whole or
    ;; fractional (so both "42" and "3.14" bind), excluding only exotic
    ;; complex-number parses like "1+2i" via real?. A second position
    ;; that's neither literal is almost certainly a typo or an
    ;; unimplemented kind, not a plain binding name -- a real plain name
    ;; is never itself written as a two-element list -- so it's caught
    ;; before the generic bare-name clause (which would otherwise treat
    ;; the whole (name kind) list as one opaque binding name and silently
    ;; miscompile) and raised as a clear error instead.
    (define-syntax surf-bind-params
      (syntax-rules (integer float)
        ((_ req () body) body)
        ((_ req ((name integer) rest ...) body)
         (let ((name (let ((raw (surf-param req (symbol->string 'name))))
                       (and raw (let ((n (string->number raw))) (and n (integer? n) n))))))
           (if name
               (surf-bind-params req (rest ...) body)
               (surf-text "Not Found" 404))))
        ((_ req ((name float) rest ...) body)
         (let ((name (let ((raw (surf-param req (symbol->string 'name))))
                       (and raw (let ((n (string->number raw))) (and n (real? n) n))))))
           (if name
               (surf-bind-params req (rest ...) body)
               (surf-text "Not Found" 404))))
        ((_ req ((name kind) rest ...) body)
         (error "surf: unknown path-param type in binding clause -- expected (name integer) or (name float)" 'kind))
        ((_ req (name rest ...) body)
         (let ((name (surf-param req (symbol->string 'name))))
           (surf-bind-params req (rest ...) body)))))

    ;; ---- hierarchical path segments -----------------------------------------

    ;; A single segment -> the runtime string it contributes to the path:
    ;; a literal segment (an ordinary string, e.g. "todos") is used as-is;
    ;; a capturing (name integer)/(name float)/(name text) segment becomes
    ;; ":name" (matching (creme mux)'s own radix path-param syntax) -- the
    ;; type only matters for surf-bind-path-segments' guard, not for the
    ;; path string itself, so all three kinds produce the same ":name"
    ;; piece here. A second position that's none of the three raises the
    ;; same clear error surf-bind-path-segments raises for the same
    ;; mistake, since a mistyped kind would otherwise silently register a
    ;; route no request could ever reach the intended guard for.
    (define-syntax surf-segment-literal
      (syntax-rules (integer float text)
        ((_ (name integer)) (string-append ":" (symbol->string 'name)))
        ((_ (name float)) (string-append ":" (symbol->string 'name)))
        ((_ (name text)) (string-append ":" (symbol->string 'name)))
        ((_ (name kind))
         (error "surf: unknown path-param type in path segment -- expected (name integer), (name float), or (name text)" 'kind))
        ((_ literal) literal)))

    ;; Joins a segment list with "/" between pieces (see surf-segment-
    ;; literal for what one piece contributes); surf-path-string (the
    ;; entry point leaf registration actually calls) prepends the leading
    ;; "/", so an empty or single "" segment list correctly yields the
    ;; root path "/" rather than an empty string.
    (define-syntax surf-join-segments
      (syntax-rules ()
        ((_ ()) "")
        ((_ (seg)) (surf-segment-literal seg))
        ((_ (seg rest ...))
         (string-append (surf-segment-literal seg) "/" (surf-join-segments (rest ...))))))

    (define-syntax surf-path-string
      (syntax-rules ()
        ((_ segs) (string-append "/" (surf-join-segments segs)))))

    ;; Binds every capturing segment in a full (prefix ++ own) segment
    ;; list, skipping literal (string) segments entirely -- they
    ;; contribute nothing here, only to the path string above. Reuses
    ;; exactly the integer/float guard semantics surf-bind-params already
    ;; established (404 instead of running body on a missing/invalid
    ;; value); `text` binds the raw surf-param value unconditionally
    ;; (there's nothing to fail-parse, and a matched route guarantees a
    ;; named path segment is always present). A bare symbol has no
    ;; meaning as a path segment (segments are always a literal string or
    ;; a (name kind) pair, never an untyped capture -- unlike a leaf's own
    ;; (req name ...) extras list, which still supports plain untyped
    ;; names via surf-bind-params below) and simply isn't matched by any
    ;; clause here, so writing one is a macro-expansion-time error rather
    ;; than a silent miscompile.
    (define-syntax surf-bind-path-segments
      (syntax-rules (integer float text)
        ((_ req () body) body)
        ((_ req ((name integer) rest ...) body)
         (let ((name (let ((raw (surf-param req (symbol->string 'name))))
                       (and raw (let ((n (string->number raw))) (and n (integer? n) n))))))
           (if name
               (surf-bind-path-segments req (rest ...) body)
               (surf-text "Not Found" 404))))
        ((_ req ((name float) rest ...) body)
         (let ((name (let ((raw (surf-param req (symbol->string 'name))))
                       (and raw (let ((n (string->number raw))) (and n (real? n) n))))))
           (if name
               (surf-bind-path-segments req (rest ...) body)
               (surf-text "Not Found" 404))))
        ((_ req ((name text) rest ...) body)
         (let ((name (surf-param req (symbol->string 'name))))
           (surf-bind-path-segments req (rest ...) body)))
        ((_ req ((name kind) rest ...) body)
         (error "surf: unknown path-param type in path segment -- expected (name integer), (name float), or (name text)" 'kind))
        ((_ req (literal rest ...) body)
         (surf-bind-path-segments req (rest ...) body))))

    ;; Registers one leaf route: `fullseg ...` is already the complete,
    ;; flattened segment list (an enclosing group's prefix plus this
    ;; leaf's own trailing segments -- see surf-clause below, which splices
    ;; the two together directly via ellipsis before ever calling this, since
    ;; a macro can't hand another macro "the result of a macro call" for
    ;; further structural matching -- syntax-rules only ever matches literal
    ;; syntax shapes, so the splice has to happen in the same template that
    ;; produces the list, not as a separate call whose own expansion is
    ;; itself unexpanded input to whatever consumes it next). Builds the mux
    ;; path string from it, binds every captured segment (guarded/typed as
    ;; declared), then binds this leaf's own extra (req name ...) list
    ;; (plain form-field-style bindings, same surf-bind-params as always)
    ;; before running body.
    (define-syntax surf-register
      (syntax-rules (get head post put delete patch)
        ((_ app get (fullseg ...) (req extra ...) body ...)
         (mux-get! app (surf-path-string (fullseg ...))
           (lambda (req)
             (surf-bind-path-segments req (fullseg ...)
               (surf-bind-params req (extra ...) (surf-normalize-response (begin body ...)))))))
        ((_ app head (fullseg ...) (req extra ...) body ...)
         (mux-head! app (surf-path-string (fullseg ...))
           (lambda (req)
             (surf-bind-path-segments req (fullseg ...)
               (surf-bind-params req (extra ...) (surf-normalize-response (begin body ...)))))))
        ((_ app post (fullseg ...) (req extra ...) body ...)
         (mux-post! app (surf-path-string (fullseg ...))
           (lambda (req)
             (surf-bind-path-segments req (fullseg ...)
               (surf-bind-params req (extra ...) (surf-normalize-response (begin body ...)))))))
        ((_ app put (fullseg ...) (req extra ...) body ...)
         (mux-put! app (surf-path-string (fullseg ...))
           (lambda (req)
             (surf-bind-path-segments req (fullseg ...)
               (surf-bind-params req (extra ...) (surf-normalize-response (begin body ...)))))))
        ((_ app delete (fullseg ...) (req extra ...) body ...)
         (mux-delete! app (surf-path-string (fullseg ...))
           (lambda (req)
             (surf-bind-path-segments req (fullseg ...)
               (surf-bind-params req (extra ...) (surf-normalize-response (begin body ...)))))))
        ((_ app patch (fullseg ...) (req extra ...) body ...)
         (mux-patch! app (surf-path-string (fullseg ...))
           (lambda (req)
             (surf-bind-path-segments req (fullseg ...)
               (surf-bind-params req (extra ...) (surf-normalize-response (begin body ...)))))))))

    ;; Processes one clause under an accumulated prefix segment list
    ;; (threaded as a spread `p ...`, not a single list-valued variable, so
    ;; it can be spliced directly alongside a clause's own `seg ...` in one
    ;; template -- see surf-register's comment for why): a leaf (method
    ;; (seg ...) (req extra ...) body ...) registers with the prefix and its
    ;; own segments spliced together (p ... seg ...); a group (at (seg ...)
    ;; clause ...) recurses into surf-clauses with that same splice as the
    ;; new prefix, so every clause nested under it -- to any depth -- sees
    ;; the combined path.
    (define-syntax surf-clause
      (syntax-rules (at get head post put delete patch)
        ((_ app (p ...) (at (seg ...) inner ...))
         (surf-clauses app (p ... seg ...) inner ...))
        ((_ app (p ...) (get (seg ...) (req extra ...) body ...))
         (surf-register app get (p ... seg ...) (req extra ...) body ...))
        ((_ app (p ...) (head (seg ...) (req extra ...) body ...))
         (surf-register app head (p ... seg ...) (req extra ...) body ...))
        ((_ app (p ...) (post (seg ...) (req extra ...) body ...))
         (surf-register app post (p ... seg ...) (req extra ...) body ...))
        ((_ app (p ...) (put (seg ...) (req extra ...) body ...))
         (surf-register app put (p ... seg ...) (req extra ...) body ...))
        ((_ app (p ...) (delete (seg ...) (req extra ...) body ...))
         (surf-register app delete (p ... seg ...) (req extra ...) body ...))
        ((_ app (p ...) (patch (seg ...) (req extra ...) body ...))
         (surf-register app patch (p ... seg ...) (req extra ...) body ...))))

    (define-syntax surf-clauses
      (syntax-rules ()
        ((_ app (p ...)) (begin))
        ((_ app (p ...) clause rest ...)
         (begin (surf-clause app (p ...) clause) (surf-clauses app (p ...) rest ...)))))

    (define-syntax surf-route!
      (syntax-rules ()
        ((_ app clause) (surf-clauses app () clause))))

    (define-syntax surf
      (syntax-rules ()
        ((_ clause ...)
         (let ((app (surf-app)))
           (surf-clauses app () clause ...)
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
    (define (surf-remote-addr request) (cdr (assoc "remote-addr" request)))

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
