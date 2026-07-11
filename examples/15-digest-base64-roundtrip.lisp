(require 'file)
(require 'digest)

(define original-path "/tmp/crisp-example-original.txt")
(define encoded-path  "/tmp/crisp-example-encoded.b64")
(define decoded-path  "/tmp/crisp-example-decoded.txt")

(define content "Transfer this payload safely as text-only base64.\n")
(file:write original-path content)

(define encoded (digest:base64-encode (file:read original-path)))
(file:write encoded-path encoded)
(println "Encoded (" (string-length encoded) " chars): " encoded)

(define decoded (digest:base64-decode (file:read encoded-path)))
(file:write decoded-path decoded)

(println "Round-trip match: " (string=? content (file:read decoded-path)))
(println "SHA-256 match:    " (string=? (digest:sha256 content) (digest:sha256 (file:read decoded-path))))

(for-each file:delete (list original-path encoded-path decoded-path))
