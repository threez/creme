;; ===========================================================================
;; A (creme spec)-based port of (creme secure-random)'s own cases -- see
;; modules/creme/spec.sld's own header comment for the framework this
;; uses, and compiler_spec.scm's own header comment for the general
;; should-match-native? approach.
;;
;; (creme secure-random) is a genuine dual-implementation module (not a
;; pure-Scheme .sld) -- native leans on Crystal's Random::Secure, cvm on
;; OpenSSL's RAND_bytes (cvm/secure_random.c), the same CSPRNG (creme
;; actor)'s own TCP/Unix handshake nonces and (creme rfc8439)'s random-
;; key/-nonce already use. should-match-native? here checks lengths/
;; shapes, never exact byte content -- these procedures are non-
;; deterministic by design.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/secure_random_spec.scm
;;   ./bin/creme --self-hosted spec/creme/secure_random_spec.scm
;;   ./cvm/cvm spec/creme/secure_random_spec.scm
;; ===========================================================================

(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme secure-random) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(describe "(creme secure-random)"
  (it "secure-random-bytes returns a bytevector of the requested length"
    (should-match-native? '((bytevector-length (secure-random-bytes 16))))
    (should-match-native? '((bytevector-length (secure-random-bytes 0)))))

  (it "secure-random-hex returns a hex string of 2n characters for n bytes"
    (should-match-native? '((string-length (secure-random-hex 16))))
    (should-match-native? '((string-length (secure-random-hex 0)))))

  (it "secure-random-base64 returns a base64 string of the expected encoded length"
    (should-match-native? '((string-length (secure-random-base64 12))))
    (should-match-native? '((string-length (secure-random-base64 1)))))

  (it "two calls never return the same bytes"
    (should-be-false? (string=? (secure-random-hex 32) (secure-random-hex 32))))

  (it "raises on a negative count"
    (should-raise? (lambda () (secure-random-bytes -1)))
    (should-raise? (lambda () (secure-random-hex -1)))
    (should-raise? (lambda () (secure-random-base64 -1))))

  (it "raises on a non-integer argument"
    (should-raise? (lambda () (secure-random-bytes "16")))))

(spec-summary!)
