require "../../spec_helper"
require "file_utils"

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "R7RS §6.13.1 Ports" do
  it "open-input-string/open-output-string/get-output-string provide textual string ports" do
    w(<<-SCM).should eq(%("\\"hello\\""))
      (define op (open-output-string))
      (write "hello" op)
      (get-output-string op)
    SCM
  end

  it "port?/input-port?/output-port?/textual-port? classify string ports correctly" do
    w(<<-SCM).should eq("(#t #f #t #t)")
      (define p (open-input-string "abc"))
      (list (port? p) (output-port? p) (input-port? p) (textual-port? p))
    SCM
  end

  it "current-output-port can be parameterize'd to redirect display/write output" do
    w(<<-SCM).should eq(%("piece by piece by piece.\\n"))
      (parameterize ((current-output-port (open-output-string)))
        (display "piece")
        (display " by piece ")
        (display "by piece.")
        (newline)
        (get-output-string (current-output-port)))
    SCM
  end

  it "open-input-bytevector/open-output-bytevector/get-output-bytevector provide binary ports" do
    w(<<-SCM).should eq("65")
      (define ip (open-input-bytevector (bytevector 65 66 67)))
      (read-u8 ip)
    SCM
  end

  it "(scheme file) provides file-backed ports/predicates under R7RS's own standard library name" do
    dir = File.tempname("creme-r7rs-ch06-13-spec", "")
    Dir.mkdir_p(dir)
    begin
      path = File.join(dir, "probe.txt")
      interp = Scheme::Interpreter.new
      Scheme.run_source(interp, <<-SCM).write_string.should eq(%("hi"))
        (import (scheme file))
        (define op (open-output-file "#{path}"))
        (write-string "hi" op)
        (close-port op)
        (call-with-input-file "#{path}" (lambda (p) (read-line p)))
      SCM
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end

describe "R7RS §6.13.2 Input" do
  it "read parses one datum's external representation from a textual input port" do
    w(<<-SCM).should eq("(a b c)")
      (import (scheme read))
      (define p (open-input-string "(a b c)"))
      (read p)
    SCM
  end

  it "read returns an eof-object when the port is exhausted" do
    w(<<-SCM).should eq("#t")
      (import (scheme read))
      (define p (open-input-string "(a b c)"))
      (read p)
      (eof-object? (read p))
    SCM
  end

  it "read-line reads up to (not including) the next end-of-line, updating the port" do
    w(%[(read-line (open-input-string "hello\\nworld"))]).should eq(%("hello"))
  end

  it "peek-char returns the next character without consuming it" do
    w(<<-SCM).should eq("(#\\w #\\w)")
      (define p (open-input-string "world"))
      (list (peek-char p) (read-char p))
    SCM
  end

  it "read-char consumes and returns the next character, updating the port to point past it" do
    w(%[(read-char (open-input-string "abc"))]).should eq("#\\a")
  end

  it "read-string reads up to k characters, or as many as available before eof" do
    w(<<-SCM).should eq(%("hel"))
      (define p (open-input-string "hello"))
      (read-string 3 p)
    SCM
  end

  it "read-u8/peek-u8/u8-ready? operate on binary ports" do
    w(<<-SCM).should eq("(65 #t)")
      (define ip (open-input-bytevector (bytevector 65 66 67)))
      (list (read-u8 ip) (u8-ready? ip))
    SCM
  end
end

describe "R7RS §6.13.3 Output" do
  it "write produces a machine-readable representation, quoting strings and escaping specials" do
    w(<<-SCM).should eq(%("\\"hi\\""))
      (define op (open-output-string))
      (write "hi" op)
      (get-output-string op)
    SCM
  end

  it "display produces a human-readable representation, without quoting strings" do
    w(<<-SCM).should eq(%("hi"))
      (define op (open-output-string))
      (display "hi" op)
      (get-output-string op)
    SCM
  end

  it "write-shared is the same as write, but represents shared/circular structure using datum labels" do
    w(<<-SCM).should eq(%("#0=(1 2 . #0#)"))
      (define op (open-output-string))
      (define x (list 1 2))
      (set-cdr! (cdr x) x)
      (write-shared x op)
      (get-output-string op)
    SCM
  end

  it "write-simple is the same as write, never emitting datum labels" do
    w(<<-SCM).should eq(%("\\"hi\\""))
      (define op (open-output-string))
      (write-simple "hi" op)
      (get-output-string op)
    SCM
  end

  it "newline writes an end-of-line to the given textual output port" do
    w(<<-SCM).should eq(%("a\\n"))
      (define op (open-output-string))
      (display "a" op)
      (newline op)
      (get-output-string op)
    SCM
  end

  it "write-char writes a single character (not its external representation) to the port" do
    w(<<-SCM).should eq(%("a"))
      (define op (open-output-string))
      (write-char #\\a op)
      (get-output-string op)
    SCM
  end

  it "write-u8 writes a single byte to a binary output port" do
    w(<<-SCM).should eq("65")
      (define op (open-output-bytevector))
      (write-u8 65 op)
      (bytevector-u8-ref (get-output-bytevector op) 0)
    SCM
  end

  it "flush-output-port flushes any buffered output, returning an unspecified value" do
    run("(flush-output-port)")
  end
end
