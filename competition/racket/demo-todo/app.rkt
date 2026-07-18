#lang racket/base
;; Racket/web-server/db/SQLite equivalent of ../../ruby/demo-todo/app.rb,
;; ../../crystal/demo-todo/src/app.cr, and ../../scheme/demo-todo/app.scm,
;; built for a head-to-head benchmark. Same storage (in-memory SQLite),
;; same routes, same row-level memoization strategy, same JSON
;; content-negotiation behavior -- written in the idiomatic Racket style
;; (web-server/dispatch routing, plain db queries, x-expressions for HTML)
;; rather than hand-porting any of the other three.

(require db
         web-server/dispatch
         web-server/servlet
         web-server/servlet-env
         web-server/http
         json
         racket/string
         racket/format)

;; --- storage ------------------------------------------------------------

(define conn (sqlite3-connect #:database 'memory))

(query-exec conn
  "CREATE TABLE todos (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0)")

;; A todo row as a small immutable struct, mirroring the field names
;; (creme dao)'s define-dao / Sequel::Model / Granite::Base all expose.
(struct todo (id title done) #:transparent)

(define (row->todo v)
  (todo (vector-ref v 0) (vector-ref v 1) (= (vector-ref v 2) 1)))

(define (add-todo! title)
  (query-exec conn "INSERT INTO todos (title, done) VALUES (?, 0)" title))

(define (todo-all)
  (map row->todo (query-rows conn "SELECT id, title, done FROM todos ORDER BY id")))

(define (todo-find id)
  (define v (query-maybe-row conn "SELECT id, title, done FROM todos WHERE id = ?" id))
  (and v (row->todo v)))

(define (todo-count-remaining)
  (query-value conn "SELECT COUNT(*) FROM todos WHERE done = 0"))

;; Mirrors (creme memoize)'s per-row cache in the Scheme version / the
;; Ruby and Crystal twins' ROW_CACHE: cache rendered row markup keyed on
;; exactly (id, done, title), so re-rendering the list only recomputes
;; rows whose fields actually changed.
(define row-cache (make-hash))

(define (toggle-todo! id)
  (define row (todo-find id))
  (when row
    (query-exec conn "UPDATE todos SET done = ? WHERE id = ?" (if (todo-done row) 0 1) id)
    (hash-remove! row-cache (list id (todo-done row) (todo-title row)))))

(define (delete-todo! id)
  (query-exec conn "DELETE FROM todos WHERE id = ?" id))

;; --- HTML (x-expressions; response/xexpr escapes string content automatically) --

(define (todo-row->xexpr id done title)
  `(li ((class ,(if done "done" "pending")))
       (form ((method "post") (action ,(format "/todos/~a/complete" id)) (class "toggle"))
             (button ((type "submit")) ,(if done "Undo" "Done")))
       (span ((class "title")) ,title)
       (form ((method "post") (action ,(format "/todos/~a/delete" id)) (class "delete"))
             (button ((type "submit")) "Delete"))))

(define (cached-todo-row->xexpr id done title)
  (hash-ref! row-cache (list id done title)
             (lambda () (todo-row->xexpr id done title))))

(define css
  (string-join
   '("body { font-family: sans-serif; }"
     ".todo-app { max-width: 28rem; margin: 2rem auto; }"
     ".todos { list-style: none; padding-left: 0; }"
     ".todos li { display: flex; align-items: center; gap: 0.5rem; padding: 4px 0; }"
     ".todos li .title { flex: 1; }"
     ".done .title { text-decoration: line-through; color: #888; }"
     "form.toggle, form.delete, form.add { display: inline; }"
     "form.add { display: flex; gap: 0.5rem; margin-bottom: 1rem; }")
   "\n"))

(define (page-xexpr)
  `(html
    (head
     (meta ((charset "utf-8")))
     (title "Todo List")
     (style ,css))
    (body
     (div ((class "todo-app"))
          (h1 "Todo List")
          (form ((method "post") (action "/todos") (class "add"))
                (input ((type "text") (name "title") (placeholder "New todo") (required "required")))
                (button ((type "submit")) "Add"))
          (ul ((class "todos"))
              ,@(for/list ([row (in-list (todo-all))])
                  (cached-todo-row->xexpr (todo-id row) (todo-done row) (todo-title row))))
          (p ((class "count")) ,(~a (todo-count-remaining) " remaining"))))))

;; --- JSON -----------------------------------------------------------------

(define (todo->jsexpr row)
  (hasheq 'id (todo-id row) 'title (todo-title row) 'done (todo-done row)))

(define (todos-json)
  (jsexpr->string (map todo->jsexpr (todo-all))))

;; --- routes -----------------------------------------------------------------

(define (accept-types req)
  (define h (headers-assq* #"Accept" (request-headers/raw req)))
  (if h
      (map (lambda (t) (string-trim (car (string-split t ";"))))
           (string-split (bytes->string/utf-8 (header-value h)) ","))
      '()))

(define (home req)
  (case (for/first ([t (in-list (accept-types req))]
                     #:when (or (string=? t "text/html") (string=? t "application/json")))
          t)
    [("text/html")
     (response/xexpr (page-xexpr) #:preamble #"<!DOCTYPE html>")]
    [("application/json")
     (response/output (lambda (out) (write-string (todos-json) out))
                       #:mime-type #"application/json; charset=utf-8")]
    [else
     (response/output
      (lambda (out) (write-string "Not Acceptable: this route serves text/html or application/json" out))
      #:code 406
      #:mime-type #"text/plain; charset=utf-8")]))

(define (create-todo req)
  (add-todo! (extract-binding/single 'title (request-bindings req)))
  (redirect-to "/"))

(define (complete-todo req id)
  (toggle-todo! id)
  (redirect-to "/"))

(define (destroy-todo req id)
  (delete-todo! id)
  (redirect-to "/"))

(define-values (dispatch mk-url)
  (dispatch-rules
   [("") home]
   [("todos") #:method "post" create-todo]
   [("todos" (integer-arg) "complete") #:method "post" complete-todo]
   [("todos" (integer-arg) "delete") #:method "post" destroy-todo]))

;; --- seed data (unconditional -- fresh in-memory DB per process) -----------

(add-todo! "Write report")
(add-todo! "Review PR")
(add-todo! "Ship release")
(toggle-todo! 2)

;; --- serve -----------------------------------------------------------------

(define port (let ([p (getenv "PORT")]) (if p (string->number p) 4567)))

(printf "Serving the todo list at http://127.0.0.1:~a\n" port)

(serve/servlet dispatch
               #:port port
               #:listen-ip "127.0.0.1"
               #:command-line? #t
               #:launch-browser? #f
               #:banner? #f
               #:servlet-regexp #rx"")
