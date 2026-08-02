require "../../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme rfc8439)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme rfc8439)) #{src}")
end

describe "rfc8439 module" do
  it "hex->bytevector and bytevector->hex round trip" do
    w(%((bytevector->hex (hex->bytevector "00:01:02:03")))).should eq(%("00010203"))
  end

  it "raises on invalid hex input" do
    expect_raises(Scheme::SchemeRuntimeError, /hex->bytevector: invalid hex string/) do
      run(%((hex->bytevector "zz")))
    end
  end

  it "random-key and random-nonce produce blobs of the right size" do
    w("(bytevector-length (rfc8439-random-key))").should eq("32")
    w("(bytevector-length (rfc8439-random-nonce))").should eq("12")
    run("(equal? (rfc8439-random-key) (rfc8439-random-key))").as(Scheme::SchemeBool).value?.should be_false
  end

  it "encrypts and decrypts a round trip without aad" do
    src = <<-SCHEME
      (let* ((key (rfc8439-random-key))
             (nonce (rfc8439-random-nonce))
             (sealed (rfc8439-encrypt key nonce "Hello World!"))
             (ciphertext (cdr (assoc "ciphertext" sealed)))
             (tag (cdr (assoc "tag" sealed)))
             (opened (rfc8439-decrypt key nonce ciphertext tag)))
        (utf8->string (cdr (assoc "plaintext" opened))))
      SCHEME
    w(src).should eq(%("Hello World!"))
  end

  it "encrypts and decrypts a round trip with aad, recovering the aad too" do
    src = <<-SCHEME
      (let* ((key (rfc8439-random-key))
             (nonce (rfc8439-random-nonce))
             (sealed (rfc8439-encrypt key nonce "secret" "header"))
             (ciphertext (cdr (assoc "ciphertext" sealed)))
             (tag (cdr (assoc "tag" sealed)))
             (opened (rfc8439-decrypt key nonce ciphertext tag)))
        (list (utf8->string (cdr (assoc "plaintext" opened)))
              (utf8->string (cdr (assoc "aad" opened)))))
      SCHEME
    w(src).should eq(%(("secret" "header")))
  end

  it "raises when the tag has been tampered with" do
    src = <<-SCHEME
      (let* ((key (rfc8439-random-key))
             (nonce (rfc8439-random-nonce))
             (sealed (rfc8439-encrypt key nonce "secret"))
             (ciphertext (cdr (assoc "ciphertext" sealed))))
        (rfc8439-decrypt key nonce ciphertext (hex->bytevector "00000000000000000000000000000000")))
      SCHEME
    expect_raises(Scheme::SchemeRuntimeError, /rfc8439-decrypt: authentication failed \(tag mismatch\)/) do
      run(src)
    end
  end

  it "raises when the ciphertext has been tampered with" do
    src = <<-SCHEME
      (let* ((key (rfc8439-random-key))
             (nonce (rfc8439-random-nonce))
             (sealed (rfc8439-encrypt key nonce "secret"))
             (ciphertext (cdr (assoc "ciphertext" sealed)))
             (tag (cdr (assoc "tag" sealed))))
        (rfc8439-decrypt key nonce (string->utf8 "tampered!") tag))
      SCHEME
    expect_raises(Scheme::SchemeRuntimeError, /rfc8439-decrypt: authentication failed \(tag mismatch\)/) do
      run(src)
    end
  end

  it "chacha20-encrypt is its own inverse" do
    src = <<-SCHEME
      (let* ((key (rfc8439-random-key))
             (nonce (rfc8439-random-nonce))
             (ciphertext (chacha20-encrypt key nonce "stream me")))
        (utf8->string (chacha20-encrypt key nonce ciphertext)))
      SCHEME
    w(src).should eq(%("stream me"))
  end

  it "poly1305-auth matches the RFC 8439 test vector" do
    src = <<-SCHEME
      (bytevector->hex
        (poly1305-auth
          (hex->bytevector "85:d6:be:78:57:55:6d:33:7f:44:52:fe:42:d5:06:a8:01:03:80:8a:fb:0d:b2:fd:4a:bf:f6:af:41:49:f5:1b")
          "Cryptographic Forum Research Group"))
      SCHEME
    w(src).should eq(%("a8061dc1305136c6c22b8baf0c0127a9"))
  end

  it "raises on non-blob/string arguments" do
    expect_raises(Scheme::SchemeRuntimeError, /poly1305-auth: expected blob or string/) do
      run(%((poly1305-auth 5 "msg")))
    end
  end
end
