require "../../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (creme secure-random)) #{src}").write_string
end

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (creme secure-random)) #{src}")
end

describe "secure-random module" do
  it "secure-random-bytes returns a bytevector of the requested length" do
    w(%((bytevector-length (secure-random-bytes 16)))).should eq("16")
    w(%((bytevector-length (secure-random-bytes 0)))).should eq("0")
  end

  it "secure-random-hex returns a hex string of 2n characters for n bytes" do
    w(%((string-length (secure-random-hex 16)))).should eq("32")
    w(%((string-length (secure-random-hex 0)))).should eq("0")
  end

  it "secure-random-base64 returns a base64 string of the expected encoded length" do
    # Standard base64 (with padding): ceil(n/3)*4 characters for n bytes.
    w(%((string-length (secure-random-base64 12)))).should eq("16")
    w(%((string-length (secure-random-base64 1)))).should eq("4")
  end

  it "two calls never return the same bytes (overwhelmingly, for a real CSPRNG)" do
    w(%((string=? (secure-random-hex 32) (secure-random-hex 32)))).should eq("#f")
  end

  it "raises on a negative count" do
    expect_raises(Creme::SchemeError) { run(%((secure-random-bytes -1))) }
    expect_raises(Creme::SchemeError) { run(%((secure-random-hex -1))) }
    expect_raises(Creme::SchemeError) { run(%((secure-random-base64 -1))) }
  end

  it "raises on a non-integer argument" do
    expect_raises(Creme::SchemeError) { run(%((secure-random-bytes "16"))) }
  end
end
