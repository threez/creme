(import (scheme base) (scheme write) (creme surf) (creme mux) (creme html) (creme css) (creme path) (creme format) (creme json-builder) (creme string) (creme sql) (creme dao))

;; Storage: SQLite, in-memory (no file to clean up). The `todo` table and its
;; CRUD are one declarative (creme dao) form -- no SQL/(creme sxql) call
;; appears anywhere in this file.
(define conn (sql-open ":memory:"))

(define-dao todo conn
  (id integer primary-key auto-increment)
  (title text not-null)
  (done integer not-null (default 0)))

(define (add-todo! title) (todo-create! 'title title 'done 0))

(define (toggle-todo! id)
  (let ((row (todo-find id)))
    (todo-update! id 'done (if (= (dao-ref row 'done) 1) 0 1))))

;; Built with html! instead of html->string: the <li>/<form>/<button>
;; skeleton here folds into precomputed string chunks at compile time: only
;; `id`/`done`/the title actually get rendered per row at runtime. Action
;; URLs are built with (creme path)'s path macro instead of hand-written
;; string-append -- (path 'todos id 'complete) folds the same way, down to
;; the same (string-append "/todos/" (number->string id) "/complete").
(define (todo-row->string row)
  (define id (dao-ref row 'id))
  (define done (= (dao-ref row 'done) 1))
  (html! `(li (@ (class ,(if done "done" "pending")))
              (form (@ (method "post") (action ,(path 'todos id 'complete)) (class "toggle"))
                    (button (@ (type "submit")) ,(if done "Undo" "Done")))
              (span (@ (class "title")) ,(dao-ref row 'title))
              (form (@ (method "post") (action ,(path 'todos id 'delete)) (class "delete"))
                    (button (@ (type "submit")) "Delete")))))

;; Built with (creme css)'s css! instead of a hand-written string: nesting
;; builds the repeated ".todos li ..." selector prefixes automatically, and
;; since this whole stylesheet is 100% static, css! folds it entirely into
;; one string literal at compile time -- zero runtime cost to render it.
(define css
  (css! ((body (font-family "sans-serif"))
         (".todo-app" (max-width "28rem") (margin "2rem auto"))
         (".todos"
          (list-style "none")
          (padding-left 0)
          ("li"
           (display "flex")
           (align-items "center")
           (gap "0.5rem")
           (padding "4px 0")
           (".title" (flex 1))))
         (".done .title" (text-decoration "line-through") (color "#888"))
         (("form.toggle" "form.delete" "form.add") (display "inline"))
         ("form.add" (display "flex") (gap "0.5rem") (margin-bottom "1rem")))))

;; Streams the whole page directly into the real HTTP response IO (via
;; (creme mux)'s port-writing "body" convention) instead of building it as
;; one big string first -- html-write! still folds every static part of
;; this template (the doctype/head/style/div/form/... skeleton) into
;; precomputed chunks at compile time; only the todos list and the
;; remaining-count text are rendered per request. Each row already comes
;; back as rendered (escaped) markup from todo-row->string, so it's
;; spliced in wrapped as (raw ...) -- otherwise it would get HTML-escaped
;; a second time, as if it were plain text rather than markup that's
;; already done.
(define (write-page! port)
  (html-write! port
    `((raw "<!DOCTYPE html>")
      (html
       (head
        (meta (@ (charset "utf-8")))
        (title "Todo List")
        (style (raw ,css)))
       (body
        (div (@ (class "todo-app"))
             (h1 "Todo List")
             (form (@ (method "post") (action "/todos") (class "add"))
                   (input (@ (type "text") (name "title") (placeholder "New todo") (required #t)))
                   (button (@ (type "submit")) "Add"))
             (ul (@ (class "todos")) ,@(map (lambda (row) (list 'raw (todo-row->string row))) (todo-all)))
             (p (@ (class "count")) ,(string-append (number->string (todo-count (lambda (row) (= (dao-ref row 'done) 0)))) " remaining"))))))))

(define (page-response) (surf-html write-page!))

;; One row's JSON shape; (todos-json) joins every row's rendered JSON with
;; "," and wraps the joined blob as a single array item -- the same
;; per-row-string-then-splice pattern write-page! already uses for HTML,
;; so no ,@-splicing machinery is needed in (creme json-builder) itself.
(define (todo->json-node row)
  `(object (id ,(dao-ref row 'id)) (title ,(dao-ref row 'title))
           (done ,(if (= (dao-ref row 'done) 1) #t #f))))

(define (todos-json)
  (json! `(array (raw ,(string-join (map (lambda (row) (json->string (todo->json-node row))) (todo-all)) ",")))))

;; Whole app's routing table as one declarative form: each clause is
;; (method path (request) body ...), registered onto a fresh router. "/"
;; is content-negotiated via surf-accept: text/html is checked FIRST, so a
;; browser whose Accept header contains both "text/html" and a "*/*"
;; fallback (or a browser extension that broadens Accept to include
;; application/json) still gets the HTML page rather than JSON -- surf-
;; accepts? treats "*/*" as matching any clause, so whichever clause is
;; listed first wins a "*/*" request; a real content-type mismatch (an
;; Accept header naming neither) is a 406, not a silent HTML fallback.
(define router
  (surf
   (get "/" (request)
     (surf-accept request
       ("text/html" (page-response))
       ("application/json" (surf-json (todos-json)))
       (else (surf-text "Not Acceptable: this route serves text/html or application/json" 406))))

   (post "/todos" (request)
     (add-todo! (cdr (assoc "title" (surf-form request))))
     (surf-redirect "/"))

   (post "/todos/:id/complete" (request)
     (toggle-todo! (string->number (surf-param request "id")))
     (surf-redirect "/"))

   (post "/todos/:id/delete" (request)
     (todo-delete! (string->number (surf-param request "id")))
     (surf-redirect "/"))))

(add-todo! "Write report")
(add-todo! "Review PR")
(add-todo! "Ship release")
(toggle-todo! 2)

(define server (mux-listen! router 0))
(display "Serving the todo list at ") (display (mux-base-url server)) (newline)
(display "Open it in a browser, then press Enter here to stop the server.") (newline)
(read-line)

(mux-close! server)
(sql-close conn)
