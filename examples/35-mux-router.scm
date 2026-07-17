(import (scheme base) (scheme write) (creme mux) (creme http))

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

(define server (mux-listen! router 0))
(define base-url (mux-base-url server))

(define greet-response (http-get (string-append base-url "/greet/scheme")))
(display "GET status: ") (display (cdr (assoc "status" greet-response))) (newline)
(display "GET body:   ") (display (cdr (assoc "body" greet-response))) (newline)

(define echo-response (http-post (string-append base-url "/echo") "round trip"))
(display "POST status: ") (display (cdr (assoc "status" echo-response))) (newline)
(display "POST body:   ") (display (cdr (assoc "body" echo-response))) (newline)

(mux-close! server)
