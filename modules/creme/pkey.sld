;; (creme pkey): thin re-export frontend over (creme builtin pkey)
(define-library (creme pkey)
  (import (creme builtin pkey))
  (export rsa-generate-key ec-generate-key pkey? pkey-private? pkey-type
          pkey-public-key pkey->pem pem->pkey pkey-sign pkey-verify
          rsa-encrypt rsa-decrypt))
