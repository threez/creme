(require 'bigdecimal)

(define line-items
  (list (cons "Widget"      "19.99")
        (cons "Gadget"      "42.50")
        (cons "Cable"        "5.25")
        (cons "Support fee" "12.00")))

(define (item-amount item) (bigdecimal:parse (cdr item)))

(define subtotal
  (reduce bigdecimal:add (bigdecimal:from-int 0) (map item-amount line-items)))

(define tax-rate (bigdecimal:parse "0.0725"))
(define tax (bigdecimal:mul subtotal tax-rate))
(define total (bigdecimal:add subtotal tax))

(for-each (lambda (item) (println (car item) ": $" (cdr item))) line-items)
(println "Subtotal: $" (bigdecimal:to-string subtotal))
(println "Tax (7.25%): $" (bigdecimal:to-string tax))
(println "Total: $" (bigdecimal:to-string total))
