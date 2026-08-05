require "../../../spec_helper"

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (creme zstd)) #{src}")
end

private def w(src : String) : String
  run(src).write_string
end

# A read-all helper + streaming compress/decompress wrappers, prepended to each
# streaming case so the expression is self-contained.
private PRELUDE = <<-SCM
  (define (read-all ip)
    (let loop ((acc (bytevector)))
      (let ((chunk (read-bytevector 4096 ip)))
        (if (eof-object? chunk) acc (loop (bytevector-append acc chunk))))))
  (define (zstream-compress bytes) (let ((ob (open-output-bytevector))) (let ((zp (zstd-open-output-port ob))) (write-bytevector bytes zp) (close-port zp)) (get-output-bytevector ob)))
  (define (zstream-decompress frame) (read-all (zstd-open-input-port (open-input-bytevector frame))))
SCM

private def ws(src : String) : String
  run("#{PRELUDE} #{src}").write_string
end

describe "zstd module" do
  # ---- one-shot ----
  it "round-trips a string through compress/decompress" do
    w(%((utf8->string (zstd-decompress (zstd-compress "hello hello hello world"))))).should eq(%("hello hello hello world"))
  end

  it "round-trips a bytevector" do
    w(%((zstd-decompress (zstd-compress (bytevector 0 1 2 3 4 250 255))))).should eq("#u8(0 1 2 3 4 250 255)")
  end

  it "honors an explicit compression level" do
    w(%((utf8->string (zstd-decompress (zstd-compress "levels payload" 19))))).should eq(%("levels payload"))
  end

  it "raises decompressing non-frame bytes" do
    expect_raises(Creme::SchemeError) { run(%((zstd-decompress (bytevector 1 2 3 4)))) }
  end

  it "raises compressing a non-blob argument" do
    expect_raises(Creme::SchemeError) { run(%((zstd-compress 42))) }
  end

  # ---- streaming filter ports ----
  it "round-trips a string through the streaming ports" do
    ws(%((utf8->string (zstream-decompress (zstream-compress (string->utf8 "streaming round trip")))))).should eq(%("streaming round trip"))
  end

  it "round-trips a bytevector through the streaming ports" do
    ws(%((zstream-decompress (zstream-compress (bytevector 0 1 2 3 250 255))))).should eq("#u8(0 1 2 3 250 255)")
  end

  it "stacks compress-over-compress and cascades close" do
    ws(%((let ((ob (open-output-bytevector)))
            (let ((zp (zstd-open-output-port (zstd-open-output-port ob))))
              (write-bytevector (string->utf8 "stacked") zp)
              (close-port zp))
            (utf8->string (read-all (zstd-open-input-port (zstd-open-input-port (open-input-bytevector (get-output-bytevector ob))))))))).should eq(%("stacked"))
  end

  it "streams a large multi-chunk payload" do
    ws(%((bytevector-length (zstream-decompress (zstream-compress (make-bytevector 200000 65)))))).should eq("200000")
  end

  it "a streaming input port also reads a one-shot frame" do
    ws(%((utf8->string (read-all (zstd-open-input-port (open-input-bytevector (zstd-compress "one-shot into stream"))))))).should eq(%("one-shot into stream"))
  end

  it "the wrapping ports are real binary ports" do
    w(%((list (output-port? (zstd-open-output-port (open-output-bytevector)))
              (binary-port? (zstd-open-output-port (open-output-bytevector)))))).should eq("(#t #t)")
  end

  it "raises opening an output port over an input port" do
    expect_raises(Creme::SchemeError) { run(%((zstd-open-output-port (open-input-bytevector (bytevector 1 2 3))))) }
  end
end
