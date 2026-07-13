; Bytevectors: building a byte buffer via a binary output port, converting
; between strings and UTF-8 bytes, and a tiny rolling checksum computed by
; indexing bytes directly — the kind of thing text strings can't do safely
; once "text" is actually opaque binary data.

(import (scheme base) (scheme write))

(define (checksum bv)
  (let loop ((i 0) (sum 0))
    (if (= i (bytevector-length bv))
        (modulo sum 256)
        (loop (+ i 1) (+ sum (bytevector-u8-ref bv i))))))

(define message (string->utf8 "hello, bytevectors"))
(display "message bytes: ") (write message) (newline)
(display "decoded back:  ") (display (utf8->string message)) (newline)
(display "checksum:      ") (display (checksum message)) (newline)

; Build a small binary record (a 2-byte length prefix + payload) using a
; binary output port, then parse it back with a binary input port.
(define (encode-record payload)
  (define out (open-output-bytevector))
  (define len (bytevector-length payload))
  (write-u8 (quotient len 256) out)
  (write-u8 (modulo len 256) out)
  (write-bytevector payload out)
  (get-output-bytevector out))

(define (decode-record bv)
  (define in (open-input-bytevector bv))
  (define hi (read-u8 in))
  (define lo (read-u8 in))
  (define len (+ (* hi 256) lo))
  (read-bytevector len in))

(define encoded (encode-record (string->utf8 "payload data")))
(display "encoded record: ") (write encoded) (newline)
(display "decoded payload: ") (display (utf8->string (decode-record encoded))) (newline)

; bytevector-copy!/bytevector-append for assembling a larger buffer from parts.
(define header (bytevector 0 1 2 3))
(define body (bytevector 10 20 30))
(display "assembled: ") (write (bytevector-append header body)) (newline)
