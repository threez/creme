;; (creme digest): thin re-export frontend over (creme builtin digest)
(define-library (creme digest)
  (import (creme builtin digest))
  (export base64-decode base64-encode digest-md5 digest-sha1 digest-sha256
          digest-sha384 digest-sha512 hmac-sha256 hmac-sha384 hmac-sha512))
