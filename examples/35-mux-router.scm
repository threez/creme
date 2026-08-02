(import (scheme base) (scheme write) (creme mux) (creme http) (creme actor))

;; Runs the router on a background (creme actor) thread with a FIXED port,
;; then retry-connects the first request in a bounded loop -- the same
;; shape spec/creme/http_spec.scm already uses (see its own header
;; comment): cvm's mux-listen! blocks its calling thread inside facil.io's
;; own reactor loop forever, by design, and never returns the port it
;; bound to back to its caller, so a script that calls mux-listen! then
;; immediately issues requests against its own server in the SAME
;; top-level thread (as this example used to) can't work there. Native's
;; own Fiber-based mux-listen! tolerates this shape fine too, so one
;; script now runs unchanged on both `./bin/creme` and `./cvm/cvm`.

(define router-port 18924)
(define (url path) (string-append "http://127.0.0.1:" (number->string router-port) path))

(spawn (lambda ()
         (define router (mux-router))

         (mux-get! router "/greet/:name"
           (lambda (request)
             (define name (cdr (assoc "name" (cdr (assoc "path-params" request)))))
             (list (cons "status" 200)
                   (cons "headers" (list (cons "content-type" "text/plain")))
                   (cons "body" (string-append "hello, " name "!")))))

         (mux-post! router "/echo"
           (lambda (request)
             (list (cons "status" 201)
                   (cons "body" (cdr (assoc "body" request))))))

         (mux-listen! router router-port (list (cons "host" "127.0.0.1")))))

(define (try-connect n)
  (guard (e (#t (if (> n 0) (try-connect (- n 1)) (error "35-mux-router: server never came up"))))
    (http-get (url "/greet/scheme"))))

(define greet-response (try-connect 500))
(display "GET status: ") (display (cdr (assoc "status" greet-response))) (newline)
(display "GET body:   ") (display (cdr (assoc "body" greet-response))) (newline)

(define echo-response (http-post (url "/echo") "round trip"))
(display "POST status: ") (display (cdr (assoc "status" echo-response))) (newline)
(display "POST body:   ") (display (cdr (assoc "body" echo-response))) (newline)
