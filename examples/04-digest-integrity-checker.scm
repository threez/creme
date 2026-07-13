(import (scheme base) (scheme write) (creme file) (creme digest))

(define path "/tmp/creme-example-integrity.txt")

(file-write path "Original important data.\n")
(define original-hash (digest-sha256 (file-read path)))
(display "Original SHA-256: ") (display original-hash) (newline)

(file-append path "An unexpected extra line was appended!\n")
(define modified-hash (digest-sha256 (file-read path)))
(display "Modified SHA-256: ") (display modified-hash) (newline)

(if (string=? original-hash modified-hash)
    (begin (display "Integrity check: OK (no changes detected)") (newline))
    (begin (display "Integrity check: FAILED (file has been modified)") (newline)))

(delete-file path)
