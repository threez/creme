(import (scheme base) (scheme write) (creme html))

(define items '("bread" "milk" "eggs"))

(define page
  `(div (@ (class "shopping-list"))
     (h1 "Shopping List")
     (ul (@ (class "items"))
         ,@(map (lambda (item) `(li ,item)) items))
     (p (@ (class "note")) "Don't forget: " (em "reusable bags") "!")
     (hr)
     (input (@ (type "checkbox") (checked #t) (disabled #f)))))

(display (html->string page))
(newline)

(display (html-document->string "Shopping List" "body { font-family: sans-serif; }" page))
(newline)
