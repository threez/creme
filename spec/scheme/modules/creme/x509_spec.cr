require "../../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (creme pkey) (creme x509)) #{src}").write_string
end

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (creme pkey) (creme x509)) #{src}")
end

describe "x509 module" do
  it "builds a self-signed certificate whose issuer equals its subject" do
    w(<<-SCHEME).should eq(%(#t))
      (define ca-key (rsa-generate-key))
      (define ca-cert (x509-self-signed-certificate ca-key '(("CN" . "Test CA") ("O" . "Test Org"))))
      (equal? (x509-cert-subject ca-cert) (x509-cert-issuer ca-cert))
      SCHEME
  end

  it "reports the subject alist for a self-signed cert" do
    w(<<-SCHEME).should eq(%((("CN" . "Test CA") ("O" . "Test Org"))))
      (define ca-key (rsa-generate-key))
      (x509-cert-subject (x509-self-signed-certificate ca-key '(("CN" . "Test CA") ("O" . "Test Org"))))
      SCHEME
  end

  it "CSR -> CA-signed cert has the CSR's subject and the CA's issuer" do
    w(<<-SCHEME).should eq(%(#t))
      (define ca-key (rsa-generate-key))
      (define ca-cert (x509-self-signed-certificate ca-key '(("CN" . "Test CA"))))
      (define leaf-key (rsa-generate-key))
      (define csr (x509-create-csr leaf-key '(("CN" . "leaf.example.com"))))
      (define leaf-cert (x509-sign-csr csr ca-cert ca-key))
      (and (equal? (x509-cert-subject leaf-cert) '(("CN" . "leaf.example.com")))
           (equal? (x509-cert-issuer leaf-cert) (x509-cert-subject ca-cert)))
      SCHEME
  end

  it "x509-verify-chain succeeds against the correct CA" do
    w(<<-SCHEME).should eq(%(#t))
      (define ca-key (rsa-generate-key))
      (define ca-cert (x509-self-signed-certificate ca-key '(("CN" . "Test CA"))))
      (define leaf-key (rsa-generate-key))
      (define csr (x509-create-csr leaf-key '(("CN" . "leaf.example.com"))))
      (define leaf-cert (x509-sign-csr csr ca-cert ca-key))
      (x509-verify-chain leaf-cert (list ca-cert))
      SCHEME
  end

  it "x509-verify-chain raises against an unrelated CA" do
    expect_raises(Creme::SchemeError) do
      run(<<-SCHEME)
        (define ca-key (rsa-generate-key))
        (define ca-cert (x509-self-signed-certificate ca-key '(("CN" . "Test CA"))))
        (define leaf-key (rsa-generate-key))
        (define csr (x509-create-csr leaf-key '(("CN" . "leaf.example.com"))))
        (define leaf-cert (x509-sign-csr csr ca-cert ca-key))
        (define other-ca-key (rsa-generate-key))
        (define other-ca-cert (x509-self-signed-certificate other-ca-key '(("CN" . "Other CA"))))
        (x509-verify-chain leaf-cert (list other-ca-cert))
        SCHEME
    end
  end

  it "round-trips a certificate through PEM" do
    w(<<-SCHEME).should eq(%(#t))
      (define ca-key (rsa-generate-key))
      (define ca-cert (x509-self-signed-certificate ca-key '(("CN" . "Test CA"))))
      (define reloaded (pem->x509-cert (x509-cert->pem ca-cert)))
      (equal? (x509-cert-subject reloaded) (x509-cert-subject ca-cert))
      SCHEME
  end

  it "not-before is before not-after, roughly matching the requested validity window" do
    w(<<-SCHEME).should eq(%(#t))
      (define ca-key (rsa-generate-key))
      (define ca-cert (x509-self-signed-certificate ca-key '(("CN" . "Test CA")) 30))
      (define nb (x509-cert-not-before ca-cert))
      (define na (x509-cert-not-after ca-cert))
      (and (< nb na) (> (/ (- na nb) 86400) 25) (< (/ (- na nb) 86400) 35))
      SCHEME
  end

  it "x509-cert-public-key extracts a public pkey usable to verify a signature made with the private key" do
    w(<<-SCHEME).should eq(%(#t))
      (define key (rsa-generate-key))
      (define cert (x509-self-signed-certificate key '(("CN" . "Test"))))
      (define pub (x509-cert-public-key cert))
      (define msg (string->utf8 "signed by cert's own key"))
      (define sig (pkey-sign key msg))
      (and (eq? (pkey-type pub) 'rsa) (not (pkey-private? pub)) (pkey-verify pub msg sig))
      SCHEME
  end

  it "works end to end with EC keys too" do
    w(<<-SCHEME).should eq(%(#t))
      (define ca-key (ec-generate-key))
      (define ca-cert (x509-self-signed-certificate ca-key '(("CN" . "EC CA"))))
      (define leaf-key (ec-generate-key))
      (define csr (x509-create-csr leaf-key '(("CN" . "ec-leaf.example.com"))))
      (define leaf-cert (x509-sign-csr csr ca-cert ca-key))
      (x509-verify-chain leaf-cert (list ca-cert))
      SCHEME
  end

  it "x509-self-signed-certificate/x509-create-csr raise when given a public-only key" do
    expect_raises(Creme::SchemeError) do
      run(%((x509-self-signed-certificate (pkey-public-key (rsa-generate-key)) '(("CN" . "x")))))
    end
    expect_raises(Creme::SchemeError) do
      run(%((x509-create-csr (pkey-public-key (rsa-generate-key)) '(("CN" . "x")))))
    end
  end

  it "pem->x509-cert raises on unrecognizable input" do
    expect_raises(Creme::SchemeError) { run(%((pem->x509-cert "not a certificate"))) }
  end
end
