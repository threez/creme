;; ===========================================================================
;; (creme bytes): byte-preserving string <-> bytevector conversions.
;;
;; File-based, pure R7RS (no records, no FFI). creme strings opened "rb"
;; (read-whole-file, file-read) are byte arrays -- each char is exactly one
;; byte -- so these copy char<->u8 verbatim, WITHOUT the re-encoding that
;; string->utf8/utf8->string would apply. Needed wherever a byte blob (an ICE
;; bytecode file, a raw file's contents) is handled as a string on one side and
;; a bytevector on the other (the ICE (de)serializer works on bytevectors while
;; file I/O here is string-based) -- e.g. icecreme's own run-file/--emit/--disassemble.
;; ===========================================================================

(define-library (creme bytes)
  (export string->bytes bytes->string list->bytevector)
  (import (scheme base))
  (begin

    ;; A bytevector from a list of u8 values, in order. (R7RS `bytevector`
    ;; takes its bytes as arguments, not a list.)
    (define (list->bytevector lst)
      (let* ((n (length lst)) (bv (make-bytevector n 0)))
        (let loop ((i 0) (l lst))
          (if (null? l)
              bv
              (begin (bytevector-u8-set! bv i (car l)) (loop (+ i 1) (cdr l)))))))

    ;; Each char -> one u8 (char->integer, assumed already in [0,255]); the
    ;; inverse of bytes->string.
    (define (string->bytes s)
      (let* ((n (string-length s)) (bv (make-bytevector n 0)))
        (let loop ((i 0))
          (if (= i n) bv
              (begin (bytevector-u8-set! bv i (char->integer (string-ref s i)))
                     (loop (+ i 1)))))))

    ;; Each u8 -> one char (integer->char); the inverse of string->bytes.
    (define (bytes->string bv)
      (let* ((n (bytevector-length bv)) (s (make-string n #\space)))
        (let loop ((i 0))
          (if (= i n) s
              (begin (string-set! s i (integer->char (bytevector-u8-ref bv i)))
                     (loop (+ i 1)))))))))
