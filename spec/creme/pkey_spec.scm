;; ===========================================================================
;; A (creme spec)-based port of (creme pkey)'s own cases -- see
;; modules/creme/spec.sld's own header comment for the framework this
;; uses, and compiler_spec.scm's own header comment for the general
;; should-match-native? approach.
;;
;; (creme pkey) is a genuine dual-implementation module -- native reuses
;; the vendored jose.cr shard's own reopened LibCryptoJose FFI bindings
;; (src/scheme/modules/creme/pkey.cr, since Crystal's stdlib has no
;; OpenSSL::PKey class hierarchy at all), cvm drives the same EVP_PKEY/
;; RSA/EC_KEY/PEM API directly in C (cvm/pkey.c, where it's simply part
;; of <openssl/evp.h>/<openssl/rsa.h>/<openssl/ec.h>/<openssl/pem.h>) --
;; both already linked via -lcrypto. RSA-OAEP-SHA256 is the only
;; encryption mode offered (no legacy PKCS1v1.5 encryption padding, the
;; real padding-oracle-vulnerable case).
;;
;; Signatures/ciphertexts are non-deterministic (RSA-OAEP/PKCS1v1.5 and
;; ECDSA both include randomness) so should-match-native? here checks
;; boolean/shape outcomes (verifies?/round-trips?/raises?), never exact
;; byte content.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/pkey_spec.scm
;;   ./bin/creme --self-hosted spec/creme/pkey_spec.scm
;;   ./cvm/cvm spec/creme/pkey_spec.scm
;; ===========================================================================

(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme pkey) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(describe "(creme pkey)"
  (it "rsa-generate-key produces a private RSA pkey"
    (should-match-native? '((pkey? (rsa-generate-key))))
    (should-match-native? '((pkey-private? (rsa-generate-key))))
    (should-match-native? '((pkey-type (rsa-generate-key)))))

  (it "ec-generate-key produces a private EC pkey"
    (should-match-native? '((pkey-type (ec-generate-key))))
    (should-match-native? '((pkey-type (ec-generate-key 'p384)))))

  (it "rsa-generate-key raises for a key smaller than 2048 bits"
    (should-raise? (lambda () (rsa-generate-key 512))))

  (it "ec-generate-key raises for an unknown curve"
    (should-raise? (lambda () (ec-generate-key 'bogus))))

  (it "pkey-public-key strips the private component"
    (should-be-false? (pkey-private? (pkey-public-key (rsa-generate-key))))
    (should-be-false? (pkey-private? (pkey-public-key (ec-generate-key)))))

  (it "round-trips a key through PEM"
    (should-be-true?
     (let* ((key (rsa-generate-key))
            (reloaded (pem->pkey (pkey->pem key))))
       (and (pkey-private? reloaded) (eq? (pkey-type reloaded) 'rsa)))))

  (it "RSA sign/verify round-trips, and fails on a tampered message or signature"
    (should-be-true?
     (let* ((key (rsa-generate-key))
            (msg (string->utf8 "hello asymmetric world"))
            (sig (pkey-sign key msg)))
       (pkey-verify (pkey-public-key key) msg sig)))
    (should-be-false?
     (let* ((key (rsa-generate-key))
            (msg (string->utf8 "hello asymmetric world"))
            (sig (pkey-sign key msg)))
       (pkey-verify (pkey-public-key key) (string->utf8 "hello asymmetric worlD") sig)))
    (should-be-false?
     (let* ((key (rsa-generate-key))
            (msg (string->utf8 "hello asymmetric world"))
            (sig (bytevector-copy (pkey-sign key msg))))
       (bytevector-u8-set! sig 0 (modulo (+ (bytevector-u8-ref sig 0) 1) 256))
       (pkey-verify (pkey-public-key key) msg sig))))

  (it "EC sign/verify round-trips, and fails on a tampered message"
    (should-be-true?
     (let* ((key (ec-generate-key))
            (msg (string->utf8 "hello asymmetric world"))
            (sig (pkey-sign key msg)))
       (pkey-verify (pkey-public-key key) msg sig)))
    (should-be-false?
     (let* ((key (ec-generate-key))
            (msg (string->utf8 "hello asymmetric world"))
            (sig (pkey-sign key msg)))
       (pkey-verify (pkey-public-key key) (string->utf8 "tampered") sig))))

  (it "pkey-sign raises when given a public-only key"
    (should-raise? (lambda () (pkey-sign (pkey-public-key (rsa-generate-key)) (string->utf8 "hi")))))

  (it "rsa-encrypt/rsa-decrypt round-trip via RSA-OAEP"
    (should-be-true?
     (let* ((key (rsa-generate-key))
            (pt (string->utf8 "rsa oaep secret"))
            (ct (rsa-encrypt (pkey-public-key key) pt)))
       (equal? (rsa-decrypt key ct) pt))))

  (it "rsa-decrypt raises on a tampered ciphertext"
    (should-raise?
     (lambda ()
       (let* ((key (rsa-generate-key))
              (ct (bytevector-copy (rsa-encrypt (pkey-public-key key) (string->utf8 "secret")))))
         (bytevector-u8-set! ct 0 (modulo (+ (bytevector-u8-ref ct 0) 1) 256))
         (rsa-decrypt key ct)))))

  (it "rsa-decrypt raises when given a public-only key"
    (should-raise?
     (lambda ()
       (let* ((key (rsa-generate-key))
              (ct (rsa-encrypt (pkey-public-key key) (string->utf8 "secret"))))
         (rsa-decrypt (pkey-public-key key) ct)))))

  (it "rsa-encrypt/rsa-decrypt raise on an EC key"
    (should-raise? (lambda () (rsa-encrypt (ec-generate-key) (string->utf8 "hi"))))
    (should-raise? (lambda () (rsa-decrypt (ec-generate-key) (string->utf8 "hi")))))

  (it "pem->pkey raises on unrecognizable input"
    (should-raise? (lambda () (pem->pkey "not a pem key at all"))))

  (it "distinguishes pkey? from other values"
    (should-match-native? '((list (pkey? (rsa-generate-key)) (pkey? "x"))))))

(spec-summary!)
