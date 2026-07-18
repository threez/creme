(import (scheme base) (scheme write) (scheme process-context) (creme surf) (creme mux) (creme html) (creme css) (creme path) (creme format) (creme json-builder) (creme string) (creme sql) (creme dao) (creme memoize))

;; A todo-list demo app for the scheme.cr-vs-Ruby benchmark in this
;; directory -- see ../../README.md and ../../results.md. Port defaults to
;; 0 (OS-assigned ephemeral, so running it directly is as easy as the
;; original example this grew out of) but a benchmark script needs a known,
;; fixed port to point wrk at -- set the PORT env var to override, e.g.
;; `PORT=4571 ./bin/creme competition/scheme/demo-todo/app.scm --lib modules`.
(define port
  (let ((p (get-environment-variable "PORT")))
    (if p (string->number p) 0)))

(define conn (sql-open ":memory:"))

(define-dao todo conn
  (id integer primary-key auto-increment)
  (title text not-null)
  (done bool not-null (default #f)))

(define (add-todo! title) (todo-create! 'title title 'done #f))

(define (toggle-todo! id)
  (let* ((row (todo-find id))
         (old-done (todo-done? row))
         (title (dao-ref row 'title)))
    (todo-update! id 'done (if old-done #f #t))
    (memoize-forget! cached-todo-row->string id old-done title)
    (memoize-forget! cached-todo-row->json id old-done title)))

(define (todo-row->string id done title)
  (html! `(li (@ (class ,(if done "done" "pending")))
              (form (@ (method "post") (action ,(path 'todos id 'complete)) (class "toggle"))
                    (button (@ (type "submit")) ,(if done "Undo" "Done")))
              (span (@ (class "title")) ,title)
              (form (@ (method "post") (action ,(path 'todos id 'delete)) (class "delete"))
                    (button (@ (type "submit")) "Delete")))))

(define cached-todo-row->string (memoize todo-row->string))

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
             (ul (@ (class "todos"))
                 ,@(map (lambda (row)
                          (list 'raw (cached-todo-row->string (dao-ref row 'id) (todo-done? row) (dao-ref row 'title))))
                        (todo-all)))
             (p (@ (class "count")) ,(string-append (number->string (todo-count (lambda (row) (not (todo-done? row))))) " remaining"))))))))

(define (page-response) (surf-html write-page!))

(define (todo-row->json id done title)
  (json->string `(object (id ,id) (title ,title) (done ,done))))

(define cached-todo-row->json (memoize todo-row->json))

(define (write-todos-json! port)
  (write-string "[" port)
  (let loop ((rows (todo-all)) (first #t))
    (if (pair? rows)
        (let ((row (car rows)))
          (if (not first) (write-string "," port))
          (write-string (cached-todo-row->json (dao-ref row 'id) (todo-done? row) (dao-ref row 'title)) port)
          (loop (cdr rows) #f))))
  (write-string "]" port))

(define router
  (surf
   (get ("") (request)
     (surf-accept request
       ("text/html" (page-response))
       ("application/json" (surf-json write-todos-json!))
       (else (surf-text "Not Acceptable: this route serves text/html or application/json" 406))))

   (post ("todos") (request title)
     (add-todo! title)
     (surf-redirect "/"))

   (at ("todos" (id integer))
     (post ("complete") (request)
       (toggle-todo! id)
       (surf-redirect "/"))

     (post ("delete") (request)
       (todo-delete! id)
       (surf-redirect "/")))))

(add-todo! "Write report")
(add-todo! "Review PR")
(add-todo! "Ship release")
(toggle-todo! 2)

(define server (mux-listen! router port))
(display "Serving the todo list at ") (display (mux-base-url server)) (newline)
(display "Press Enter here to stop the server.") (newline)
(read-line)

(mux-close! server)
(sql-close conn)
