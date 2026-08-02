;; ===========================================================================
;; A (creme spec)-based port of (creme cipher)'s own cases -- see
;; modules/creme/spec.sld's own header comment for the framework this
;; uses, and compiler_spec.scm's own header comment for the general
;; should-match-native? approach.
;;
;; (creme cipher) is a genuine dual-implementation module -- native
;; drives OpenSSL's raw EVP AEAD API by reopening Crystal's own
;; OpenSSL::LibCrypto binding (src/scheme/modules/creme/cipher.cr, see
;; its own header comment for why: Crystal's high-level OpenSSL::Cipher
;; wrapper has no GCM/AEAD support at all in this Crystal version), cvm
;; drives the same EVP AEAD API directly in C (cvm/cipher.c) -- both
;; already linked via -lcrypto. Scoped to AES-256-GCM only (no raw
;; CBC/ECB), the same AEAD-first cut (creme rfc8439) already made for
;; ChaCha20-Poly1305.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/cipher_spec.scm
;;   ./bin/creme --self-hosted spec/creme/cipher_spec.scm
;;   ./cvm/cvm spec/creme/cipher_spec.scm
;; ===========================================================================

(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme cipher) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(describe "(creme cipher)"
  (it "matches the published GCM test vector (256-bit zero key/nonce, empty plaintext/aad)"
    (should-match-native?
     '((cdr (assoc "tag" (aes-256-gcm-encrypt (make-bytevector 32 0) (make-bytevector 12 0) (make-bytevector 0)))))))

  (it "round-trips encrypt/decrypt without aad"
    (should-be-true?
     (let* ((key (aes-256-gcm-random-key))
            (nonce (aes-256-gcm-random-nonce))
            (pt (string->utf8 "hello world, this is a secret message"))
            (enc (aes-256-gcm-encrypt key nonce pt))
            (dec (aes-256-gcm-decrypt key nonce (cdr (assoc "ciphertext" enc)) (cdr (assoc "tag" enc)))))
       (equal? dec pt))))

  (it "round-trips encrypt/decrypt with aad"
    (should-be-true?
     (let* ((key (aes-256-gcm-random-key))
            (nonce (aes-256-gcm-random-nonce))
            (pt (string->utf8 "hello world"))
            (aad (string->utf8 "some-aad"))
            (enc (aes-256-gcm-encrypt key nonce pt aad))
            (dec (aes-256-gcm-decrypt key nonce (cdr (assoc "ciphertext" enc)) (cdr (assoc "tag" enc)) aad)))
       (equal? dec pt))))

  (it "raises rather than succeeding on a tampered ciphertext byte"
    (should-raise?
     (lambda ()
       (let* ((key (aes-256-gcm-random-key))
              (nonce (aes-256-gcm-random-nonce))
              (enc (aes-256-gcm-encrypt key nonce (string->utf8 "hello")))
              (ct (bytevector-copy (cdr (assoc "ciphertext" enc)))))
         (bytevector-u8-set! ct 0 (modulo (+ (bytevector-u8-ref ct 0) 1) 256))
         (aes-256-gcm-decrypt key nonce ct (cdr (assoc "tag" enc)))))))

  (it "raises rather than succeeding on a tampered tag byte"
    (should-raise?
     (lambda ()
       (let* ((key (aes-256-gcm-random-key))
              (nonce (aes-256-gcm-random-nonce))
              (enc (aes-256-gcm-encrypt key nonce (string->utf8 "hello")))
              (tag (bytevector-copy (cdr (assoc "tag" enc)))))
         (bytevector-u8-set! tag 0 (modulo (+ (bytevector-u8-ref tag 0) 1) 256))
         (aes-256-gcm-decrypt key nonce (cdr (assoc "ciphertext" enc)) tag)))))

  (it "raises rather than succeeding with the wrong aad"
    (should-raise?
     (lambda ()
       (let* ((key (aes-256-gcm-random-key))
              (nonce (aes-256-gcm-random-nonce))
              (enc (aes-256-gcm-encrypt key nonce (string->utf8 "hello") (string->utf8 "aad"))))
         (aes-256-gcm-decrypt key nonce (cdr (assoc "ciphertext" enc)) (cdr (assoc "tag" enc)) (string->utf8 "wrong"))))))

  (it "raises rather than succeeding with the wrong key"
    (should-raise?
     (lambda ()
       (let* ((nonce (aes-256-gcm-random-nonce))
              (enc (aes-256-gcm-encrypt (aes-256-gcm-random-key) nonce (string->utf8 "hello"))))
         (aes-256-gcm-decrypt (aes-256-gcm-random-key) nonce (cdr (assoc "ciphertext" enc)) (cdr (assoc "tag" enc)))))))

  (it "raises on a wrong-size key"
    (should-raise? (lambda () (aes-256-gcm-encrypt (make-bytevector 16 0) (aes-256-gcm-random-nonce) (string->utf8 "hi")))))

  (it "raises on a wrong-size nonce"
    (should-raise? (lambda () (aes-256-gcm-encrypt (aes-256-gcm-random-key) (make-bytevector 8 0) (string->utf8 "hi")))))

  (it "raises on a wrong-size tag"
    (should-raise?
     (lambda ()
       (let* ((key (aes-256-gcm-random-key))
              (nonce (aes-256-gcm-random-nonce)))
         (aes-256-gcm-decrypt key nonce (string->utf8 "hi") (make-bytevector 4 0))))))

  (it "random-key/random-nonce return the expected byte lengths and never repeat"
    (should-match-native? '((bytevector-length (aes-256-gcm-random-key))))
    (should-match-native? '((bytevector-length (aes-256-gcm-random-nonce))))
    (should-be-false? (equal? (aes-256-gcm-random-key) (aes-256-gcm-random-key)))))

(spec-summary!)
