;; (creme cipher): thin re-export frontend over (creme builtin cipher)
(define-library (creme cipher)
  (import (creme builtin cipher))
  (export aes-256-gcm-encrypt aes-256-gcm-decrypt aes-256-gcm-random-key
          aes-256-gcm-random-nonce))
