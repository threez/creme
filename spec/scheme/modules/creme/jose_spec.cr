require "../../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme jose)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme jose)) #{src}")
end

describe "jose module" do
  it "generates an oct key recognized by jose-jwk?" do
    w("(jose-jwk? (jose-jwk-generate-oct))").should eq("#t")
    w("(jose-jwk? 42)").should eq("#f")
    w("(jose-jwk-kty (jose-jwk-generate-oct))").should eq(%("oct"))
  end

  it "generates an EC key and strips private material via to-public" do
    src = <<-SCHEME
      (let* ((priv (jose-jwk-generate-ec))
             (pub (jose-jwk-to-public priv)))
        (list (jose-jwk-private? priv) (jose-jwk-public? pub)))
      SCHEME
    w(src).should eq("(#t #t)")
  end

  it "signs and verifies a JWS round trip with an oct/HS256 key" do
    src = <<-SCHEME
      (let* ((jwk (jose-jwk-generate-oct))
             (signed (jose-jws-sign jwk "hello world"))
             (result (jose-jws-verify jwk signed)))
        (list (cdr (assoc "valid" result)) (cdr (assoc "payload" result))))
      SCHEME
    w(src).should eq(%((#t "hello world")))
  end

  it "rejects a tampered JWS signature without raising" do
    src = <<-SCHEME
      (let* ((jwk (jose-jwk-generate-oct))
             (other (jose-jwk-generate-oct))
             (signed (jose-jws-sign jwk "hello world"))
             (result (jose-jws-verify other signed)))
        (cdr (assoc "valid" result)))
      SCHEME
    w(src).should eq("#f")
  end

  it "signs claims as a JWT and verifies them back as an alist" do
    src = <<-SCHEME
      (let* ((jwk (jose-jwk-generate-oct))
             (token (jose-jwt-sign jwk (list (cons "sub" "alice") (cons "iss" "example.com"))))
             (result (jose-jwt-verify jwk (list "HS256") token (list (cons "iss" "example.com")))))
        (list (cdr (assoc "valid" result)) (cdr (assoc "sub" (cdr (assoc "claims" result))))))
      SCHEME
    w(src).should eq(%((#t "alice")))
  end

  it "rejects a JWT with the wrong expected issuer" do
    src = <<-SCHEME
      (let* ((jwk (jose-jwk-generate-oct))
             (token (jose-jwt-sign jwk (list (cons "sub" "alice") (cons "iss" "example.com"))))
             (result (jose-jwt-verify jwk (list "HS256") token (list (cons "iss" "someone-else.com")))))
        (cdr (assoc "valid" result)))
      SCHEME
    w(src).should eq("#f")
  end

  it "encrypts and decrypts a JWE round trip with a password" do
    src = <<-SCHEME
      (let* ((token (jose-jwe-password-encrypt "correct horse battery staple" "sensitive data")))
        (jose-jwe-password-decrypt "correct horse battery staple" token))
      SCHEME
    w(src).should eq(%("sensitive data"))
  end

  it "encrypts and decrypts a JWE JSON round trip with a jwk" do
    src = <<-SCHEME
      (let* ((jwk (jose-jwk-generate-oct))
             (token (jose-jwe-json-encrypt jwk "hello json")))
        (jose-jwe-json-decrypt jwk token))
      SCHEME
    w(src).should eq(%("hello json"))
  end

  it "builds a JWKS, looks up by kid, and returns #f for a missing kid" do
    src = <<-SCHEME
      (let* ((k1 (jose-jwk-with-kid (jose-jwk-generate-ec) "sig"))
             (k2 (jose-jwk-with-kid (jose-jwk-generate-oct) "enc"))
             (jwks (jose-jwks-new (list k1 k2))))
        (list (jose-jwks-size jwks)
              (jose-jwk-kty (jose-jwks-ref jwks "enc"))
              (jose-jwks-ref jwks "missing")))
      SCHEME
    w(src).should eq(%((2 "oct" #f)))
  end

  it "raises a SchemeRuntimeError for garbage PEM input" do
    expect_raises(Scheme::SchemeRuntimeError, /jose-jwk-from-pem/) do
      run(%((jose-jwk-from-pem "not a pem")))
    end
  end
end
