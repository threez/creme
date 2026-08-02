;; ===========================================================================
;; A (creme spec)-based port of (creme digest)'s own cases -- see
;; modules/creme/spec.sld's own header comment for the framework this
;; uses, and compiler_spec.scm's own header comment for the general
;; should-match-native? approach.
;;
;; (creme digest) used to be entirely absent from icecreme. Crystal's own
;; `require "digest/md5"`/`sha1`/`sha256`/`sha512`/`openssl/digest`/
;; `openssl/hmac`/`base64` are all Crystal STANDARD LIBRARY, not external
;; shards (see shard.yml) -- backed here (icecreme/digest.c) by OpenSSL's
;; EVP_Digest/HMAC (already linked via -lcrypto, from (creme actor)'s own
;; HMAC-SHA256 handshake) plus a small hand-rolled base64 codec.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/digest_spec.scm
;;   ./bin/creme --self-hosted spec/creme/digest_spec.scm
;;   ./icecreme/icecreme spec/creme/digest_spec.scm
;; ===========================================================================

;; See compiler_spec.scm's own comment on why the full toolchain import
;; list is still needed here even though (creme compiler spec-helper)
;; already imports all of it for itself.
(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme digest) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(describe "(creme digest)"
  (it "hashes with md5, sha1, sha256"
    (should-match-native? '((digest-md5 "hello")))
    (should-match-native? '((digest-sha1 "hello")))
    (should-match-native? '((digest-sha256 "hello"))))

  (it "hashes with sha384, sha512"
    (should-match-native? '((digest-sha384 "abc")))
    (should-match-native? '((digest-sha512 "abc"))))

  (it "computes hmac-sha256/384/512"
    (should-match-native? '((hmac-sha256 "Jefe" "what do ya want for nothing?")))
    (should-match-native? '((hmac-sha384 "Jefe" "what do ya want for nothing?")))
    (should-match-native? '((hmac-sha512 "Jefe" "what do ya want for nothing?"))))

  (it "base64 encodes and decodes round trip"
    (should-match-native? '((base64-encode "hello")))
    (should-match-native? '((base64-decode (base64-encode "hello")))))

  (it "raises on invalid base64 input"
    (should-raise? (lambda () (base64-decode "not valid base64!!"))))

  (it "raises on non-string arguments"
    (should-raise? (lambda () (digest-md5 5)))))

(spec-summary!)
