(import (scheme base) (scheme write) (creme file) (creme digest))

(define original-path "/tmp/creme-example-original.txt")
(define encoded-path  "/tmp/creme-example-encoded.b64")
(define decoded-path  "/tmp/creme-example-decoded.txt")

(define content "Transfer this payload safely as text-only base64.\n")
(file-write original-path content)

(define encoded (base64-encode (file-read original-path)))
(file-write encoded-path encoded)
(display "Encoded (") (display (string-length encoded)) (display " chars): ") (display encoded) (newline)

(define decoded (base64-decode (file-read encoded-path)))
(file-write decoded-path decoded)

(display "Round-trip match: ") (display (string=? content (file-read decoded-path))) (newline)
(display "SHA-256 match:    ") (display (string=? (digest-sha256 content) (digest-sha256 (file-read decoded-path)))) (newline)

(for-each delete-file (list original-path encoded-path decoded-path))
