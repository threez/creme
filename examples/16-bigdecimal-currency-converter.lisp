(require 'bigdecimal)

(define rates
  (list (cons "USD" (bigdecimal:parse "1.00"))
        (cons "EUR" (bigdecimal:parse "0.92"))
        (cons "GBP" (bigdecimal:parse "0.79"))
        (cons "JPY" (bigdecimal:parse "157.20"))))

(define (convert amount from-code to-code)
  (let ((from-rate (cdr (assoc from-code rates)))
        (to-rate   (cdr (assoc to-code rates))))
    (bigdecimal:div (bigdecimal:mul amount to-rate) from-rate)))

(define amount (bigdecimal:parse "250.00"))

(for-each
  (lambda (code)
    (println "250.00 USD -> " code ": " (bigdecimal:to-string (convert amount "USD" code))))
  (list "EUR" "GBP" "JPY"))
