(import (scheme base) (scheme write) (creme rfc8439))

(define key (rfc8439-random-key))
(define nonce (rfc8439-random-nonce))
(define message "The launch code is 7734.")
(define header "priority: urgent")

(display "Key:     ") (display (bytevector->hex key)) (newline)
(display "Nonce:   ") (display (bytevector->hex nonce)) (newline)
(display "Message: ") (display message) (newline)

(define sealed (rfc8439-encrypt key nonce message header))
(define ciphertext (cdr (assoc "ciphertext" sealed)))
(define tag (cdr (assoc "tag" sealed)))

(display "Ciphertext: ") (display (bytevector->hex ciphertext)) (newline)
(display "Tag:        ") (display (bytevector->hex tag)) (newline)

(define opened (rfc8439-decrypt key nonce ciphertext tag))
(define recovered (utf8->string (cdr (assoc "plaintext" opened))))
(define recovered-aad (utf8->string (cdr (assoc "aad" opened))))

(display "Recovered message: ") (display recovered) (newline)
(display "Recovered header:  ") (display recovered-aad) (newline)
(display "Round-trip match:  ") (display (string=? message recovered)) (newline)
(display "AAD round-trip match: ") (display (string=? header recovered-aad)) (newline)
