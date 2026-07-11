require "../../spec_helper"

private def w(src : String) : String
  interp = LISP::Interpreter.new
  LISP.run_source(interp, "(require 'rfc8439) #{src}").write_string
end

private def run(src : String) : LISP::LispValue
  interp = LISP::Interpreter.new
  LISP.run_source(interp, "(require 'rfc8439) #{src}")
end

describe "rfc8439 module" do
  it "hex->blob and blob->hex round trip" do
    w(%((rfc8439:blob->hex (rfc8439:hex->blob "00:01:02:03")))).should eq(%("00010203"))
  end

  it "raises on invalid hex input" do
    expect_raises(LISP::LispRuntimeError, /rfc8439:hex->blob: invalid hex string/) do
      run(%((rfc8439:hex->blob "zz")))
    end
  end

  it "random-key and random-nonce produce blobs of the right size" do
    w("(blob-size (rfc8439:random-key))").should eq("32")
    w("(blob-size (rfc8439:random-nonce))").should eq("12")
    run("(equal? (rfc8439:random-key) (rfc8439:random-key))").as(LISP::LispBool).value.should be_false
  end

  it "encrypts and decrypts a round trip without aad" do
    src = <<-LISP
      (let* ((key (rfc8439:random-key))
             (nonce (rfc8439:random-nonce))
             (sealed (rfc8439:encrypt key nonce "Hello World!"))
             (ciphertext (cdr (assoc "ciphertext" sealed)))
             (tag (cdr (assoc "tag" sealed)))
             (opened (rfc8439:decrypt key nonce ciphertext tag)))
        (blob->string (cdr (assoc "plaintext" opened))))
      LISP
    w(src).should eq(%("Hello World!"))
  end

  it "encrypts and decrypts a round trip with aad, recovering the aad too" do
    src = <<-LISP
      (let* ((key (rfc8439:random-key))
             (nonce (rfc8439:random-nonce))
             (sealed (rfc8439:encrypt key nonce "secret" "header"))
             (ciphertext (cdr (assoc "ciphertext" sealed)))
             (tag (cdr (assoc "tag" sealed)))
             (opened (rfc8439:decrypt key nonce ciphertext tag)))
        (list (blob->string (cdr (assoc "plaintext" opened)))
              (blob->string (cdr (assoc "aad" opened)))))
      LISP
    w(src).should eq(%(("secret" "header")))
  end

  it "raises when the tag has been tampered with" do
    src = <<-LISP
      (let* ((key (rfc8439:random-key))
             (nonce (rfc8439:random-nonce))
             (sealed (rfc8439:encrypt key nonce "secret"))
             (ciphertext (cdr (assoc "ciphertext" sealed))))
        (rfc8439:decrypt key nonce ciphertext (rfc8439:hex->blob "00000000000000000000000000000000")))
      LISP
    expect_raises(LISP::LispRuntimeError, /rfc8439:decrypt: authentication failed \(tag mismatch\)/) do
      run(src)
    end
  end

  it "raises when the ciphertext has been tampered with" do
    src = <<-LISP
      (let* ((key (rfc8439:random-key))
             (nonce (rfc8439:random-nonce))
             (sealed (rfc8439:encrypt key nonce "secret"))
             (ciphertext (cdr (assoc "ciphertext" sealed)))
             (tag (cdr (assoc "tag" sealed))))
        (rfc8439:decrypt key nonce (string->blob "tampered!") tag))
      LISP
    expect_raises(LISP::LispRuntimeError, /rfc8439:decrypt: authentication failed \(tag mismatch\)/) do
      run(src)
    end
  end

  it "chacha20-encrypt is its own inverse" do
    src = <<-LISP
      (let* ((key (rfc8439:random-key))
             (nonce (rfc8439:random-nonce))
             (ciphertext (rfc8439:chacha20-encrypt key nonce "stream me")))
        (blob->string (rfc8439:chacha20-encrypt key nonce ciphertext)))
      LISP
    w(src).should eq(%("stream me"))
  end

  it "poly1305-auth matches the RFC 8439 test vector" do
    src = <<-LISP
      (rfc8439:blob->hex
        (rfc8439:poly1305-auth
          (rfc8439:hex->blob "85:d6:be:78:57:55:6d:33:7f:44:52:fe:42:d5:06:a8:01:03:80:8a:fb:0d:b2:fd:4a:bf:f6:af:41:49:f5:1b")
          "Cryptographic Forum Research Group"))
      LISP
    w(src).should eq(%("a8061dc1305136c6c22b8baf0c0127a9"))
  end

  it "raises on non-blob/string arguments" do
    expect_raises(LISP::LispRuntimeError, /rfc8439:poly1305-auth: expected blob or string/) do
      run(%((rfc8439:poly1305-auth 5 "msg")))
    end
  end
end
