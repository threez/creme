;; (creme jose): thin re-export frontend over (creme builtin jose)
(define-library (creme jose)
  (import (creme builtin jose))
  (export jose-jwe-decrypt jose-jwe-encrypt jose-jwe-json-decrypt
          jose-jwe-json-encrypt jose-jwe-password-decrypt
          jose-jwe-password-encrypt jose-jwk-from-json jose-jwk-from-oct
          jose-jwk-from-pem jose-jwk-generate-ec jose-jwk-generate-oct
          jose-jwk-generate-okp jose-jwk-generate-rsa jose-jwk-kty
          jose-jwk-private? jose-jwk-public? jose-jwk-to-json
          jose-jwk-to-pem jose-jwk-to-public jose-jwk-with-kid jose-jwk?
          jose-jwks-new jose-jwks-ref jose-jwks-size jose-jwks-to-public
          jose-jwks? jose-jws-sign jose-jws-sign-detached
          jose-jws-sign-json jose-jws-verify jose-jws-verify-detached
          jose-jws-verify-json jose-jwt-sign jose-jwt-verify))
