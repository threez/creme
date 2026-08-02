require "../../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (scheme base) (creme pkey)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (scheme base) (creme pkey)) #{src}")
end

describe "pkey module" do
  it "rsa-generate-key produces a private RSA pkey" do
    w(%((pkey? (rsa-generate-key)))).should eq("#t")
    w(%((pkey-private? (rsa-generate-key)))).should eq("#t")
    w(%((pkey-type (rsa-generate-key)))).should eq("rsa")
  end

  it "ec-generate-key produces a private EC pkey" do
    w(%((pkey-type (ec-generate-key)))).should eq("ec")
    w(%((pkey-type (ec-generate-key 'p384)))).should eq("ec")
  end

  it "rsa-generate-key raises for a key smaller than 2048 bits" do
    expect_raises(Scheme::SchemeError) { run(%((rsa-generate-key 512))) }
  end

  it "ec-generate-key raises for an unknown curve" do
    expect_raises(Scheme::SchemeError) { run(%((ec-generate-key 'bogus))) }
  end

  it "pkey-public-key strips the private component" do
    w(<<-SCHEME).should eq(%(#f))
      (pkey-private? (pkey-public-key (rsa-generate-key)))
      SCHEME
    w(<<-SCHEME).should eq(%(#f))
      (pkey-private? (pkey-public-key (ec-generate-key)))
      SCHEME
  end

  it "round-trips a key through PEM" do
    w(<<-SCHEME).should eq(%(#t))
      (define key (rsa-generate-key))
      (define reloaded (pem->pkey (pkey->pem key)))
      (and (pkey-private? reloaded) (eq? (pkey-type reloaded) 'rsa))
      SCHEME
  end

  it "RSA sign/verify round-trips, and fails on a tampered message or signature" do
    w(<<-SCHEME).should eq(%(#t))
      (define key (rsa-generate-key))
      (define msg (string->utf8 "hello asymmetric world"))
      (define sig (pkey-sign key msg))
      (pkey-verify (pkey-public-key key) msg sig)
      SCHEME
    w(<<-SCHEME).should eq(%(#f))
      (define key (rsa-generate-key))
      (define msg (string->utf8 "hello asymmetric world"))
      (define sig (pkey-sign key msg))
      (pkey-verify (pkey-public-key key) (string->utf8 "hello asymmetric worlD") sig)
      SCHEME
    w(<<-SCHEME).should eq(%(#f))
      (define key (rsa-generate-key))
      (define msg (string->utf8 "hello asymmetric world"))
      (define sig (bytevector-copy (pkey-sign key msg)))
      (bytevector-u8-set! sig 0 (modulo (+ (bytevector-u8-ref sig 0) 1) 256))
      (pkey-verify (pkey-public-key key) msg sig)
      SCHEME
  end

  it "EC sign/verify round-trips, and fails on a tampered message or signature" do
    w(<<-SCHEME).should eq(%(#t))
      (define key (ec-generate-key))
      (define msg (string->utf8 "hello asymmetric world"))
      (define sig (pkey-sign key msg))
      (pkey-verify (pkey-public-key key) msg sig)
      SCHEME
    w(<<-SCHEME).should eq(%(#f))
      (define key (ec-generate-key))
      (define msg (string->utf8 "hello asymmetric world"))
      (define sig (pkey-sign key msg))
      (pkey-verify (pkey-public-key key) (string->utf8 "tampered") sig)
      SCHEME
  end

  it "pkey-sign raises when given a public-only key" do
    expect_raises(Scheme::SchemeError) do
      run(%((pkey-sign (pkey-public-key (rsa-generate-key)) (string->utf8 "hi"))))
    end
  end

  it "rsa-encrypt/rsa-decrypt round-trip via RSA-OAEP" do
    w(<<-SCHEME).should eq(%(#t))
      (define key (rsa-generate-key))
      (define pt (string->utf8 "rsa oaep secret"))
      (define ct (rsa-encrypt (pkey-public-key key) pt))
      (equal? (rsa-decrypt key ct) pt)
      SCHEME
  end

  it "rsa-decrypt raises on a tampered ciphertext" do
    expect_raises(Scheme::SchemeError) do
      run(<<-SCHEME)
        (define key (rsa-generate-key))
        (define ct (bytevector-copy (rsa-encrypt (pkey-public-key key) (string->utf8 "secret"))))
        (bytevector-u8-set! ct 0 (modulo (+ (bytevector-u8-ref ct 0) 1) 256))
        (rsa-decrypt key ct)
        SCHEME
    end
  end

  it "rsa-decrypt raises when given a public-only key" do
    expect_raises(Scheme::SchemeError) do
      run(<<-SCHEME)
        (define key (rsa-generate-key))
        (define ct (rsa-encrypt (pkey-public-key key) (string->utf8 "secret")))
        (rsa-decrypt (pkey-public-key key) ct)
        SCHEME
    end
  end

  it "rsa-encrypt/rsa-decrypt raise on an EC key" do
    expect_raises(Scheme::SchemeError) { run(%((rsa-encrypt (ec-generate-key) (string->utf8 "hi")))) }
    expect_raises(Scheme::SchemeError) { run(%((rsa-decrypt (ec-generate-key) (string->utf8 "hi")))) }
  end

  it "pem->pkey raises on unrecognizable input" do
    expect_raises(Scheme::SchemeError) { run(%((pem->pkey "not a pem key at all"))) }
  end

  it "distinguishes pkey? from other values" do
    w(%((list (pkey? (rsa-generate-key)) (pkey? "x")))).should eq("(#t #f)")
  end
end
