;; (creme rfc8439): thin re-export frontend over (creme builtin rfc8439)
(define-library (creme rfc8439)
  (import (creme builtin rfc8439))
  (export bytevector->hex chacha20-encrypt hex->bytevector poly1305-auth
          rfc8439-decrypt rfc8439-encrypt rfc8439-random-key
          rfc8439-random-nonce))
