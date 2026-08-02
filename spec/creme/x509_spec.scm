;; ===========================================================================
;; A (creme spec)-based port of (creme x509)'s own cases -- see
;; modules/creme/spec.sld's own header comment for the framework this
;; uses, and compiler_spec.scm's own header comment for the general
;; should-match-native? approach.
;;
;; (creme x509) is a genuine dual-implementation module -- native reopens
;; Crystal's own OpenSSL::LibCrypto binding to add every X509/ASN1
;; declaration it needs (src/scheme/modules/creme/x509.cr, since neither
;; Crystal's stdlib nor the vendored jose.cr shard bind a certificate-
;; building/chain-verification surface), cvm drives the same X509/
;; X509_REQ/X509_STORE API directly in C (cvm/x509.c, where it's simply
;; part of <openssl/x509.h>/<openssl/x509v3.h>) -- both already linked
;; via -lcrypto.
;;
;; Certificates/CSRs embed a randomly-generated key's signature, so
;; should-match-native? here checks boolean/shape outcomes (subject/
;; issuer alists, verifies?/raises?), never exact PEM byte content.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/x509_spec.scm
;;   ./bin/creme --self-hosted spec/creme/x509_spec.scm
;;   ./cvm/cvm spec/creme/x509_spec.scm
;; ===========================================================================

(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme pkey) (creme x509) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(describe "(creme x509)"
  (it "builds a self-signed certificate whose issuer equals its subject"
    (should-be-true?
     (let* ((ca-key (rsa-generate-key))
            (ca-cert (x509-self-signed-certificate ca-key '(("CN" . "Test CA") ("O" . "Test Org")))))
       (equal? (x509-cert-subject ca-cert) (x509-cert-issuer ca-cert)))))

  (it "reports the subject alist for a self-signed cert"
    (should-match-native?
     '((x509-cert-subject (x509-self-signed-certificate (rsa-generate-key) '(("CN" . "Test CA") ("O" . "Test Org")))))))

  (it "CSR -> CA-signed cert has the CSR's subject and the CA's issuer"
    (should-be-true?
     (let* ((ca-key (rsa-generate-key))
            (ca-cert (x509-self-signed-certificate ca-key '(("CN" . "Test CA"))))
            (leaf-key (rsa-generate-key))
            (csr (x509-create-csr leaf-key '(("CN" . "leaf.example.com"))))
            (leaf-cert (x509-sign-csr csr ca-cert ca-key)))
       (and (equal? (x509-cert-subject leaf-cert) '(("CN" . "leaf.example.com")))
            (equal? (x509-cert-issuer leaf-cert) (x509-cert-subject ca-cert))))))

  (it "x509-verify-chain succeeds against the correct CA"
    (should-be-true?
     (let* ((ca-key (rsa-generate-key))
            (ca-cert (x509-self-signed-certificate ca-key '(("CN" . "Test CA"))))
            (leaf-key (rsa-generate-key))
            (csr (x509-create-csr leaf-key '(("CN" . "leaf.example.com"))))
            (leaf-cert (x509-sign-csr csr ca-cert ca-key)))
       (x509-verify-chain leaf-cert (list ca-cert)))))

  (it "x509-verify-chain raises against an unrelated CA"
    (should-raise?
     (lambda ()
       (let* ((ca-key (rsa-generate-key))
              (ca-cert (x509-self-signed-certificate ca-key '(("CN" . "Test CA"))))
              (leaf-key (rsa-generate-key))
              (csr (x509-create-csr leaf-key '(("CN" . "leaf.example.com"))))
              (leaf-cert (x509-sign-csr csr ca-cert ca-key))
              (other-ca-key (rsa-generate-key))
              (other-ca-cert (x509-self-signed-certificate other-ca-key '(("CN" . "Other CA")))))
         (x509-verify-chain leaf-cert (list other-ca-cert))))))

  (it "round-trips a certificate through PEM"
    (should-be-true?
     (let* ((ca-key (rsa-generate-key))
            (ca-cert (x509-self-signed-certificate ca-key '(("CN" . "Test CA"))))
            (reloaded (pem->x509-cert (x509-cert->pem ca-cert))))
       (equal? (x509-cert-subject reloaded) (x509-cert-subject ca-cert)))))

  (it "not-before is before not-after, roughly matching the requested validity window"
    (should-be-true?
     (let* ((ca-key (rsa-generate-key))
            (ca-cert (x509-self-signed-certificate ca-key '(("CN" . "Test CA")) 30))
            (nb (x509-cert-not-before ca-cert))
            (na (x509-cert-not-after ca-cert)))
       (and (< nb na) (> (/ (- na nb) 86400) 25) (< (/ (- na nb) 86400) 35)))))

  (it "x509-cert-public-key extracts a public pkey usable to verify a signature made with the private key"
    (should-be-true?
     (let* ((key (rsa-generate-key))
            (cert (x509-self-signed-certificate key '(("CN" . "Test"))))
            (pub (x509-cert-public-key cert))
            (msg (string->utf8 "signed by cert's own key"))
            (sig (pkey-sign key msg)))
       (and (eq? (pkey-type pub) 'rsa) (not (pkey-private? pub)) (pkey-verify pub msg sig)))))

  (it "works end to end with EC keys too"
    (should-be-true?
     (let* ((ca-key (ec-generate-key))
            (ca-cert (x509-self-signed-certificate ca-key '(("CN" . "EC CA"))))
            (leaf-key (ec-generate-key))
            (csr (x509-create-csr leaf-key '(("CN" . "ec-leaf.example.com"))))
            (leaf-cert (x509-sign-csr csr ca-cert ca-key)))
       (x509-verify-chain leaf-cert (list ca-cert)))))

  (it "x509-self-signed-certificate/x509-create-csr raise when given a public-only key"
    (should-raise? (lambda () (x509-self-signed-certificate (pkey-public-key (rsa-generate-key)) '(("CN" . "x")))))
    (should-raise? (lambda () (x509-create-csr (pkey-public-key (rsa-generate-key)) '(("CN" . "x"))))))

  (it "pem->x509-cert raises on unrecognizable input"
    (should-raise? (lambda () (pem->x509-cert "not a certificate")))))

(spec-summary!)
