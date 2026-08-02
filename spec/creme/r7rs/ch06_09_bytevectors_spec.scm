;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/r7rs/ch06_09_bytevectors_spec.
;; cr's own cases -- see modules/creme/spec.sld's own header comment for
;; the framework this uses, and spec/creme/r7rs/ch06_13_input_output_spec.
;; scm's own header comment for this project's existing precedent of
;; testing directly (no string-embedding-and-sub-eval needed, since this
;; file already runs in a real Scheme runtime). See spec/creme/bytevectors_
;; spec.scm for the byte-PORT half of (scheme base)'s bytevector surface
;; (open-input-bytevector/read-u8/etc.) -- this file only covers the plain
;; bytevector-value operations §6.9 itself documents.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/r7rs/ch06_09_bytevectors_spec.scm
;;   ./bin/creme --self-hosted spec/creme/r7rs/ch06_09_bytevectors_spec.scm
;;   ./cvm/cvm spec/creme/r7rs/ch06_09_bytevectors_spec.scm
;; ===========================================================================

(import (scheme base) (scheme write) (creme spec))

(define (write-to-string v)
  (let ((port (open-output-string)))
    (write v port)
    (get-output-string port)))

(describe "R7RS §6.9 Bytevectors"
  (it "bytevector? is #t for bytevector objects"
    (should-be-true? (bytevector? #u8(1 2 3)))
    (should-be-false? (bytevector? (vector 1 2 3))))

  (it "write produces R7RS's #u8(byte ...) external representation for bytevectors"
    (should-equal? (write-to-string (bytevector 1 2 3)) "#u8(1 2 3)"))

  (it "make-bytevector returns a newly allocated bytevector of k elements, optionally initialized to byte"
    (should-equal? (bytevector-length (make-bytevector 2 12)) 2)
    (should-equal? (bytevector-u8-ref (make-bytevector 2 12) 0) 12))

  (it "bytevector returns a newly allocated bytevector containing its byte arguments"
    (should-equal? (bytevector-length (bytevector 1 3 5 1 3 5)) 6)
    (should-equal? (bytevector-u8-ref (bytevector 1 3 5 1 3 5) 2) 5))

  (it "bytevector-length returns the number of bytes"
    (should-equal? (bytevector-length #u8(1 2 3)) 3))

  (it "bytevector-u8-ref returns the kth byte"
    (should-equal? (bytevector-u8-ref '#u8(1 1 2 3 5 8 13 21) 5) 8))

  (it "bytevector-u8-set! stores byte as the kth byte"
    (should-equal?
     (let ((bv (bytevector 1 2 3 4)))
       (bytevector-u8-set! bv 1 3)
       (bytevector-u8-ref bv 1))
     3))

  (it "bytevector-copy returns a newly allocated bytevector containing the given byte range"
    (should-equal?
     (let ((bv (bytevector-copy #u8(1 2 3 4 5) 2 4)))
       (list (bytevector-u8-ref bv 0) (bytevector-u8-ref bv 1)))
     (list 3 4)))

  (it "bytevector-copy! copies a range of bytes from one bytevector into another at a given offset"
    (should-equal?
     (let ((bv (bytevector 1 2 3 4 5)))
       (bytevector-copy! bv 1 (bytevector 10 20 30 40 50) 0 2)
       (list (bytevector-u8-ref bv 0) (bytevector-u8-ref bv 1) (bytevector-u8-ref bv 2)
             (bytevector-u8-ref bv 3) (bytevector-u8-ref bv 4)))
     (list 1 10 20 4 5)))

  (it "bytevector-append returns a newly allocated concatenation of its bytevector arguments"
    (should-equal?
     (let ((bv (bytevector-append #u8(0 1 2) #u8(3 4 5))))
       (list (bytevector-u8-ref bv 0) (bytevector-u8-ref bv 1) (bytevector-u8-ref bv 2)
             (bytevector-u8-ref bv 3) (bytevector-u8-ref bv 4) (bytevector-u8-ref bv 5)))
     (list 0 1 2 3 4 5)))

  (it "utf8->string/string->utf8 translate between a bytevector and a string via UTF-8"
    (should-equal? (utf8->string #u8(65)) "A")))

(spec-summary!)
