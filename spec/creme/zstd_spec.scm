;; ===========================================================================
;; A (creme spec)-based port of (creme zstd)'s own cases -- see
;; modules/creme/spec.sld's own header comment for the framework this uses,
;; and compiler_spec.scm's own header comment for the general
;; should-match-native? approach.
;;
;; (creme zstd) wraps libzstd (facebook/zstd, BSD-3-Clause) on both backends:
;;   * one-shot zstd-compress/zstd-decompress (bytevector<->bytevector), an
;;     embedded-content-size frame -- byte-identical across backends, so those
;;     cases use should-match-native?.
;;   * streaming, composable FILTER ports (zstd-open-output-port/-input-port)
;;     that wrap another port; their frames are streamed (no content size), and
;;     their exact bytes can differ across backends, so those cases assert on the
;;     round-tripped PLAINTEXT with should-equal? instead of comparing frames.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/zstd_spec.scm
;;   ./bin/creme --self-hosted spec/creme/zstd_spec.scm
;;   ./icecreme/icecreme spec/creme/zstd_spec.scm
;; ===========================================================================

(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme zstd) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

;; Read an input port to EOF (streaming reads come back in chunks).
(define (read-all ip)
  (let loop ((acc (bytevector)))
    (let ((chunk (read-bytevector 4096 ip)))
      (if (eof-object? chunk) acc (loop (bytevector-append acc chunk))))))

;; Compress `bytes` through a streaming output filter port -> the frame bytes.
(define (zstream-compress bytes . level)
  (let ((ob (open-output-bytevector)))
    (let ((zp (if (pair? level) (zstd-open-output-port ob (car level)) (zstd-open-output-port ob))))
      (write-bytevector bytes zp)
      (close-port zp))
    (get-output-bytevector ob)))

;; Decompress a frame through a streaming input filter port -> the plaintext.
(define (zstream-decompress frame)
  (read-all (zstd-open-input-port (open-input-bytevector frame))))

(describe "(creme zstd)"
  ;; ---- one-shot codec (byte-identical across backends) ----
  (it "compress/decompress round-trips a string"
    (should-match-native? '((utf8->string (zstd-decompress (zstd-compress "hello, hello, hello, hello, world"))))))

  (it "compress/decompress round-trips a bytevector"
    (should-match-native? '((zstd-decompress (zstd-compress (bytevector 0 1 2 3 4 5 250 255))))))

  (it "round-trips the empty input"
    (should-match-native? '((zstd-decompress (zstd-compress "")))))

  (it "honors an explicit compression level"
    (should-match-native? '((utf8->string (zstd-decompress (zstd-compress "level nineteen payload payload payload" 19))))))

  (it "one-shot output is deterministic across backends"
    (should-match-native? '((zstd-compress "deterministic zstd frame zzzzzzzz"))))

  ;; ---- streaming filter ports (assert on round-tripped plaintext) ----
  (it "a compressing output port round-trips through a decompressing input port"
    (should-equal? (utf8->string (zstream-decompress (zstream-compress (string->utf8 "streaming filter port payload"))))
                   "streaming filter port payload"))

  (it "round-trips a bytevector through the streaming ports"
    (should-equal? (zstream-decompress (zstream-compress (bytevector 0 1 2 3 4 5 250 255)))
                   (bytevector 0 1 2 3 4 5 250 255)))

  (it "round-trips the empty input through the streaming ports"
    (should-equal? (zstream-decompress (zstream-compress (bytevector))) (bytevector)))

  (it "honors a level on the streaming output port"
    (should-equal? (utf8->string (zstream-decompress (zstream-compress (string->utf8 "level 19 streaming") 19)))
                   "level 19 streaming"))

  (it "stacks filter ports: compress-over-compress round-trips (cascade close)"
    (let ((ob (open-output-bytevector)))
      (let ((zp (zstd-open-output-port (zstd-open-output-port ob))))
        (write-bytevector (string->utf8 "stacked filter ports") zp)
        (close-port zp)) ; one close cascades through both layers down to ob
      (should-equal?
        (utf8->string (read-all (zstd-open-input-port (zstd-open-input-port (open-input-bytevector (get-output-bytevector ob))))))
        "stacked filter ports")))

  (it "streams a large multi-chunk payload with bounded memory"
    (should-equal? (bytevector-length (zstream-decompress (zstream-compress (make-bytevector 200000 65)))) 200000))

  (it "a streaming input port also reads a one-shot frame"
    (should-equal? (utf8->string (read-all (zstd-open-input-port (open-input-bytevector (zstd-compress "one-shot into a streaming port")))))
                   "one-shot into a streaming port"))

  (it "the wrapping ports satisfy the port predicates"
    (should-be-true? (output-port? (zstd-open-output-port (open-output-bytevector))))
    (should-be-true? (input-port? (zstd-open-input-port (open-input-bytevector (zstd-compress "x")))))
    (should-be-true? (binary-port? (zstd-open-output-port (open-output-bytevector)))))

  (it "call-with-port finalizes and cascades the stack"
    (let ((ob (open-output-bytevector)))
      (call-with-port (zstd-open-output-port ob)
        (lambda (zp) (write-bytevector (string->utf8 "via call-with-port") zp)))
      (should-equal? (utf8->string (zstream-decompress (get-output-bytevector ob))) "via call-with-port")))

  ;; ---- errors ----
  (it "one-shot zstd-decompress raises on non-frame garbage"
    (should-raise? (lambda () (zstd-decompress (bytevector 1 2 3 4)))))

  (it "zstd-compress raises on a non-blob argument"
    (should-raise? (lambda () (zstd-compress 42))))

  (it "zstd-open-output-port raises on a non-output port"
    (should-raise? (lambda () (zstd-open-output-port (open-input-bytevector (bytevector 1 2 3)))))))

(spec-summary!)
