(require 'rfc8439)

(define key (rfc8439:random-key))
(define nonce (rfc8439:random-nonce))
(define message "The launch code is 7734.")
(define header "priority: urgent")

(println "Key:     " (rfc8439:blob->hex key))
(println "Nonce:   " (rfc8439:blob->hex nonce))
(println "Message: " message)

(define sealed (rfc8439:encrypt key nonce message header))
(define ciphertext (cdr (assoc "ciphertext" sealed)))
(define tag (cdr (assoc "tag" sealed)))

(println "Ciphertext: " (rfc8439:blob->hex ciphertext))
(println "Tag:        " (rfc8439:blob->hex tag))

(define opened (rfc8439:decrypt key nonce ciphertext tag))
(define recovered (blob->string (cdr (assoc "plaintext" opened))))
(define recovered-aad (blob->string (cdr (assoc "aad" opened))))

(println "Recovered message: " recovered)
(println "Recovered header:  " recovered-aad)
(println "Round-trip match:  " (string=? message recovered))
(println "AAD round-trip match: " (string=? header recovered-aad))
