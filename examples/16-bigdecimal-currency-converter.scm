(import (scheme base) (scheme write) (creme bigdecimal))

(define rates
  (list (cons "USD" (string->bigdecimal "1.00"))
        (cons "EUR" (string->bigdecimal "0.92"))
        (cons "GBP" (string->bigdecimal "0.79"))
        (cons "JPY" (string->bigdecimal "157.20"))))

(define (convert amount from-code to-code)
  (let ((from-rate (cdr (assoc from-code rates)))
        (to-rate   (cdr (assoc to-code rates))))
    (bigdecimal-div (bigdecimal-mul amount to-rate) from-rate)))

(define amount (string->bigdecimal "250.00"))

(for-each
  (lambda (code)
    (display "250.00 USD -> ") (display code) (display ": ") (display (bigdecimal->string (convert amount "USD" code))) (newline))
  (list "EUR" "GBP" "JPY"))
