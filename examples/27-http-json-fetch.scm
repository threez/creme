(import (scheme base) (scheme write) (creme http) (creme json))

(define response (http-get "https://postman-echo.com/get?lang=scheme"))
(define status (cdr (assoc "status" response)))
(define body (json-read (cdr (assoc "body" response))))

(display "GET status: ") (display status) (newline)
(display "GET args:   ") (display (json-write (cdr (assoc "args" body)))) (newline)

(define post-response
  (http-post "https://postman-echo.com/post"
             (json-write '(("name" . "creme") ("kind" . "scheme")))
             '(("Content-Type" . "application/json"))))
(define post-body (json-read (cdr (assoc "body" post-response))))

(display "POST status: ") (display (cdr (assoc "status" post-response))) (newline)
(display "POST echo:   ") (display (json-write (cdr (assoc "data" post-body)))) (newline)
