require "../../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (creme cipher)) #{src}").write_string
end

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (creme cipher)) #{src}")
end

describe "cipher module" do
  it "matches the published GCM test vector (256-bit zero key/nonce, empty plaintext/aad)" do
    w(%((cdr (assoc "tag" (aes-256-gcm-encrypt (make-bytevector 32 0) (make-bytevector 12 0) (make-bytevector 0))))))
      .should eq("#u8(83 15 138 251 199 69 54 185 169 99 180 241 196 203 115 139)")
  end

  it "round-trips encrypt/decrypt, with and without aad" do
    w(<<-SCHEME).should eq(%(#t))
      (define key (aes-256-gcm-random-key))
      (define nonce (aes-256-gcm-random-nonce))
      (define pt (string->utf8 "hello world, this is a secret message"))
      (define enc (aes-256-gcm-encrypt key nonce pt))
      (define dec (aes-256-gcm-decrypt key nonce (cdr (assoc "ciphertext" enc)) (cdr (assoc "tag" enc))))
      (equal? dec pt)
      SCHEME

    w(<<-SCHEME).should eq(%(#t))
      (define key (aes-256-gcm-random-key))
      (define nonce (aes-256-gcm-random-nonce))
      (define pt (string->utf8 "hello world"))
      (define aad (string->utf8 "some-aad"))
      (define enc (aes-256-gcm-encrypt key nonce pt aad))
      (define dec (aes-256-gcm-decrypt key nonce (cdr (assoc "ciphertext" enc)) (cdr (assoc "tag" enc)) aad))
      (equal? dec pt)
      SCHEME
  end

  it "raises rather than succeeding on a tampered ciphertext byte" do
    expect_raises(Creme::SchemeError) do
      run(<<-SCHEME)
        (define key (aes-256-gcm-random-key))
        (define nonce (aes-256-gcm-random-nonce))
        (define enc (aes-256-gcm-encrypt key nonce (string->utf8 "hello")))
        (define ct (bytevector-copy (cdr (assoc "ciphertext" enc))))
        (bytevector-u8-set! ct 0 (modulo (+ (bytevector-u8-ref ct 0) 1) 256))
        (aes-256-gcm-decrypt key nonce ct (cdr (assoc "tag" enc)))
        SCHEME
    end
  end

  it "raises rather than succeeding on a tampered tag byte" do
    expect_raises(Creme::SchemeError) do
      run(<<-SCHEME)
        (define key (aes-256-gcm-random-key))
        (define nonce (aes-256-gcm-random-nonce))
        (define enc (aes-256-gcm-encrypt key nonce (string->utf8 "hello")))
        (define tag (bytevector-copy (cdr (assoc "tag" enc))))
        (bytevector-u8-set! tag 0 (modulo (+ (bytevector-u8-ref tag 0) 1) 256))
        (aes-256-gcm-decrypt key nonce (cdr (assoc "ciphertext" enc)) tag)
        SCHEME
    end
  end

  it "raises rather than succeeding with the wrong aad" do
    expect_raises(Creme::SchemeError) do
      run(<<-SCHEME)
        (define key (aes-256-gcm-random-key))
        (define nonce (aes-256-gcm-random-nonce))
        (define enc (aes-256-gcm-encrypt key nonce (string->utf8 "hello") (string->utf8 "aad")))
        (aes-256-gcm-decrypt key nonce (cdr (assoc "ciphertext" enc)) (cdr (assoc "tag" enc)) (string->utf8 "wrong"))
        SCHEME
    end
  end

  it "raises rather than succeeding with the wrong key" do
    expect_raises(Creme::SchemeError) do
      run(<<-SCHEME)
        (define nonce (aes-256-gcm-random-nonce))
        (define enc (aes-256-gcm-encrypt (aes-256-gcm-random-key) nonce (string->utf8 "hello")))
        (aes-256-gcm-decrypt (aes-256-gcm-random-key) nonce (cdr (assoc "ciphertext" enc)) (cdr (assoc "tag" enc)))
        SCHEME
    end
  end

  it "raises on a wrong-size key" do
    expect_raises(Creme::SchemeError) do
      run(%((aes-256-gcm-encrypt (make-bytevector 16 0) (aes-256-gcm-random-nonce) (string->utf8 "hi"))))
    end
  end

  it "raises on a wrong-size nonce" do
    expect_raises(Creme::SchemeError) do
      run(%((aes-256-gcm-encrypt (aes-256-gcm-random-key) (make-bytevector 8 0) (string->utf8 "hi"))))
    end
  end

  it "raises on a wrong-size tag" do
    expect_raises(Creme::SchemeError) do
      run(<<-SCHEME)
        (define key (aes-256-gcm-random-key))
        (define nonce (aes-256-gcm-random-nonce))
        (aes-256-gcm-decrypt key nonce (string->utf8 "hi") (make-bytevector 4 0))
        SCHEME
    end
  end

  it "random-key/random-nonce return the expected byte lengths and never repeat" do
    w(%((bytevector-length (aes-256-gcm-random-key)))).should eq("32")
    w(%((bytevector-length (aes-256-gcm-random-nonce)))).should eq("12")
    w(%((equal? (aes-256-gcm-random-key) (aes-256-gcm-random-key)))).should eq("#f")
  end
end
