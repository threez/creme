(require 'http)
(require 'json)

(define response (http:get "https://postman-echo.com/get?lang=lisp"))
(define status (cdr (assoc "status" response)))
(define body (json:parse (cdr (assoc "body" response))))

(println "GET status: " status)
(println "GET args:   " (json:stringify (cdr (assoc "args" body))))

(define post-response
  (http:post "https://postman-echo.com/post"
             (json:stringify '(("name" . "crisp") ("kind" . "lisp")))
             '(("Content-Type" . "application/json"))))
(define post-body (json:parse (cdr (assoc "body" post-response))))

(println "POST status: " (cdr (assoc "status" post-response)))
(println "POST echo:   " (json:stringify (cdr (assoc "data" post-body))))
