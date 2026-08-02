require "../../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme digest)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme digest)) #{src}")
end

describe "digest module" do
  it "hashes with md5, sha1, sha256" do
    w(%((digest-md5 "hello"))).should eq(%("5d41402abc4b2a76b9719d911017c592"))
    w(%((digest-sha1 "hello"))).should eq(%("aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d"))
    w(%((digest-sha256 "hello"))).should eq(%("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"))
  end

  it "hashes with sha384, sha512" do
    w(%((digest-sha384 "abc")))
      .should eq(%("cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7"))
    w(%((digest-sha512 "abc")))
      .should eq(%("ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"))
  end

  it "accepts a bytevector argument for the wider (new) digest-*/hmac-* procedures" do
    w(%((digest-sha512 (string->utf8 "abc"))))
      .should eq(%("ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"))
  end

  it "computes HMAC-SHA256/384/512, matching RFC 4231 test case 2 (key=\"Jefe\")" do
    w(%((hmac-sha256 "Jefe" "what do ya want for nothing?")))
      .should eq(%("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"))
    w(%((hmac-sha384 "Jefe" "what do ya want for nothing?")))
      .should eq(%("af45d2e376484031617f78d2b58a6b1b9c7ef464f5a01b47e42ec3736322445e8e2240ca5e69e2c78b3239ecfab21649"))
    w(%((hmac-sha512 "Jefe" "what do ya want for nothing?")))
      .should eq(%("164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea2505549758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737"))
  end

  it "base64 encodes and decodes round trip" do
    w(%((base64-encode "hello"))).should eq(%("aGVsbG8="))
    w(%((base64-decode (base64-encode "hello")))).should eq(%("hello"))
  end

  it "raises on invalid base64 input" do
    expect_raises(Scheme::SchemeRuntimeError, /base64-decode: invalid base64/) do
      run(%((base64-decode "not valid base64!!")))
    end
  end

  it "raises on non-string arguments" do
    expect_raises(Scheme::SchemeRuntimeError, /digest-md5: expected string/) do
      run("(digest-md5 5)")
    end
  end
end
