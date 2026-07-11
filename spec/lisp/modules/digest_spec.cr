require "../../spec_helper"

private def w(src : String) : String
  interp = LISP::Interpreter.new
  LISP.run_source(interp, "(require 'digest) #{src}").write_string
end

private def run(src : String) : LISP::LispValue
  interp = LISP::Interpreter.new
  LISP.run_source(interp, "(require 'digest) #{src}")
end

describe "digest module" do
  it "hashes with md5, sha1, sha256" do
    w(%((digest:md5 "hello"))).should eq(%("5d41402abc4b2a76b9719d911017c592"))
    w(%((digest:sha1 "hello"))).should eq(%("aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d"))
    w(%((digest:sha256 "hello"))).should eq(%("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"))
  end

  it "base64 encodes and decodes round trip" do
    w(%((digest:base64-encode "hello"))).should eq(%("aGVsbG8="))
    w(%((digest:base64-decode (digest:base64-encode "hello")))).should eq(%("hello"))
  end

  it "raises on invalid base64 input" do
    expect_raises(LISP::LispRuntimeError, /digest:base64-decode: invalid base64/) do
      run(%((digest:base64-decode "not valid base64!!")))
    end
  end

  it "raises on non-string arguments" do
    expect_raises(LISP::LispRuntimeError, /digest:md5: expected string/) do
      run("(digest:md5 5)")
    end
  end
end
