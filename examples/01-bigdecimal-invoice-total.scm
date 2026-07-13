(import (scheme base) (scheme write) (creme bigdecimal))

(define (reduce-list f init lst)
  (if (null? lst) init (reduce-list f (f init (car lst)) (cdr lst))))

(define line-items
  (list (cons "Widget"      "19.99")
        (cons "Gadget"      "42.50")
        (cons "Cable"        "5.25")
        (cons "Support fee" "12.00")))

(define (item-amount item) (string->bigdecimal (cdr item)))

(define subtotal
  (reduce-list bigdecimal-add (integer->bigdecimal 0) (map item-amount line-items)))

(define tax-rate (string->bigdecimal "0.0725"))
(define tax (bigdecimal-mul subtotal tax-rate))
(define total (bigdecimal-add subtotal tax))

(for-each (lambda (item) (display (car item)) (display ": $") (display (cdr item)) (newline)) line-items)
(display "Subtotal: $") (display (bigdecimal->string subtotal)) (newline)
(display "Tax (7.25%): $") (display (bigdecimal->string tax)) (newline)
(display "Total: $") (display (bigdecimal->string total)) (newline)
