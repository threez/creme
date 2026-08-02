;; ===========================================================================
;; A (creme spec)-based functional smoke test for
;; competition/scheme/demo-todo/app.scm -- see modules/creme/spec.sld's own
;; header comment for the framework this uses.
;;
;; competition/bench.scm's todo-app suite only ever checks that each app's
;; port comes up (wait-for-port!, a bare GET /) before throwing wrk load at
;; it -- it never checks that add/toggle/delete/JSON actually behave
;; correctly. A wrk run against a server that's up but subtly broken (a bad
;; migration, a form-parsing regression, a route wired to the wrong
;; handler) would still happily report a req/s number, silently comparing
;; garbage. This spec exercises the app's real routes end-to-end -- add,
;; list (HTML + JSON), toggle, delete -- against a freshly spawned instance
;; of the exact same app.scm the bench suite points wrk at, so a regression
;; fails loudly here instead of just quietly skewing a benchmark table.
;;
;; Spawns app.scm as its own subprocess via (creme process)'s process-
;; spawn/process-run (same pattern competition/bench.scm's own run-todo-
;; app-suite! uses to start every app it benchmarks -- see that file's
;; wait-for-port!/cleanup! helpers), on a fixed port distinct from any of
;; bench.scm's own --*-port defaults, so this can run standalone or
;; alongside a bench run without clashing. Works the same under any
;; backend that can run this spec file itself (native, --self-hosted, or
;; ./icecreme/icecreme) since process-spawn always shells out to a real
;; ./bin/creme child regardless.
;;
;; Run with:
;;   ./bin/creme competition/scheme/demo-todo/app_spec.scm
;; ===========================================================================

(import (scheme base) (scheme write) (scheme cxr) (creme spec) (creme process)
        (creme shell) (creme http) (creme json) (creme string) (only (creme extra) filter))

(define smoke-port "18929")
(define (url path) (string-append "http://127.0.0.1:" smoke-port path))

(define app-pid
  (process-spawn "./bin/creme" (list "competition/scheme/demo-todo/app.scm")
                 'env (list (cons "PORT" smoke-port))
                 'stdout "/tmp/demo-todo-app-spec.log" 'stderr "/tmp/demo-todo-app-spec.log"
                 'stdin 'keep-open))

(define (app-alive?)
  (guard (e (#t #f))
    (http-get (url "/") (list (cons "Accept" "text/html")))
    #t))

(guard (e (#t (display "demo-todo app.scm never came up on port ") (display smoke-port) (newline)
              (process-kill! app-pid)
              (exit 1)))
  (shell-wait-until! app-alive?))

(define (get-html) (cdr (assoc "body" (http-get (url "/") (list (cons "Accept" "text/html"))))))
;; json-read hands back a JSON array as a vector (matching json_spec.scm's
;; own contract), not a list -- converted here once so every caller below
;; can use plain list operations (map/filter/length) on the rows.
(define (get-json) (vector->list (json-read (cdr (assoc "body" (http-get (url "/") (list (cons "Accept" "application/json"))))))))

(define (add-todo! title) (http-post (url "/todos") (string-append "title=" (surf-url-encode title))))
(define (complete-todo! id) (http-post (url (string-append "/todos/" (number->string id) "/complete")) ""))
(define (delete-todo! id) (http-post (url (string-append "/todos/" (number->string id) "/delete")) ""))

;; (creme surf)'s own surf-url-decode turns "+" into a space (application/
;; x-www-form-urlencoded), so this only ever needs to encode the one
;; character these test titles actually contain.
(define (surf-url-encode s)
  (list->string
   (apply append
          (map (lambda (c) (if (char=? c #\space) (list #\+) (list c)))
               (string->list s)))))

(define (todo-titles json) (map (lambda (row) (cdr (assoc "title" row))) json))
(define (todo-ref json title) (car (filter (lambda (row) (equal? (cdr (assoc "title" row)) title)) json)))

(describe "competition/scheme/demo-todo/app.scm"

  (it "seeds three todos, one already done"
    (let ((rows (get-json)))
      (should-equal? (length rows) 3)
      (should-equal? (todo-titles rows) (list "Write report" "Review PR" "Ship release"))
      (should-be-false? (cdr (assoc "done" (todo-ref rows "Write report"))))
      (should-be-true? (cdr (assoc "done" (todo-ref rows "Review PR"))))
      (should-be-false? (cdr (assoc "done" (todo-ref rows "Ship release"))))))

  (it "renders the seeded todos and remaining-count in the HTML page"
    (let ((html (get-html)))
      (should-be-true? (string-contains? html "Write report"))
      (should-be-true? (string-contains? html "Review PR"))
      (should-be-true? (string-contains? html "Ship release"))
      (should-be-true? (string-contains? html "2 remaining"))))

  (it "returns 406 for an unsupported Accept type"
    (should-equal? (cdr (assoc "status" (http-get (url "/") (list (cons "Accept" "application/xml"))))) 406))

  (it "adds a new todo via POST /todos and redirects home"
    (let ((response (add-todo! "Buy milk")))
      (should-equal? (cdr (assoc "status" response)) 303)
      (should-equal? (cdr (assoc "Location" (cdr (assoc "headers" response)))) "/"))
    (let ((rows (get-json)))
      (should-equal? (length rows) 4)
      (should-be-false? (cdr (assoc "done" (todo-ref rows "Buy milk"))))))

  (it "toggles a todo's done state via POST /todos/:id/complete"
    (let* ((id (cdr (assoc "id" (todo-ref (get-json) "Buy milk"))))
           (response (complete-todo! id)))
      (should-equal? (cdr (assoc "status" response)) 303)
      (should-be-true? (cdr (assoc "done" (todo-ref (get-json) "Buy milk"))))
      (complete-todo! id) ; toggle back to #f, so delete below removes a not-done row like the others
      (should-be-false? (cdr (assoc "done" (todo-ref (get-json) "Buy milk"))))))

  (it "deletes a todo via POST /todos/:id/delete"
    (let* ((id (cdr (assoc "id" (todo-ref (get-json) "Buy milk"))))
           (response (delete-todo! id)))
      (should-equal? (cdr (assoc "status" response)) 303)
      (let ((rows (get-json)))
        (should-equal? (length rows) 3)
        (should-equal? (todo-titles rows) (list "Write report" "Review PR" "Ship release"))))))

(process-kill! app-pid)

(spec-summary!)
