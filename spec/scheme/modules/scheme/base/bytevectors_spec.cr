require "../../../../spec_helper"

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "#u8(...) reader syntax" do
  it "reads a bytevector literal" do
    w("#u8(1 2 3)").should eq("#u8(1 2 3)")
  end

  it "reads an empty bytevector" do
    w("#u8()").should eq("#u8()")
  end

  it "raises for an out-of-range byte value" do
    expect_raises(Creme::SchemeParseError, /out of range/) { run("#u8(256)") }
    expect_raises(Creme::SchemeParseError, /out of range/) { run("#u8(-1)") }
  end

  it "raises for a non-integer element" do
    expect_raises(Creme::SchemeParseError, /must be integers/) { run("#u8(1.5)") }
    expect_raises(Creme::SchemeParseError, /must be integers/) { run(%[#u8("x")]) }
  end
end

describe "bytevector construction" do
  it "bytevector builds from arguments" do
    w("(bytevector 1 2 3)").should eq("#u8(1 2 3)")
    w("(bytevector)").should eq("#u8()")
  end

  it "make-bytevector fills with 0 by default, or a given byte" do
    w("(make-bytevector 3)").should eq("#u8(0 0 0)")
    w("(make-bytevector 3 9)").should eq("#u8(9 9 9)")
  end

  it "bytevector? distinguishes bytevectors from other types" do
    w("(bytevector? (bytevector 1))").should eq("#t")
    w("(bytevector? \"x\")").should eq("#f")
    w("(bytevector? (vector 1))").should eq("#f")
  end

  it "equal? compares bytevectors by content, eq?/eqv? by identity" do
    w("(equal? (bytevector 1 2) (bytevector 1 2))").should eq("#t")
    w("(eq? (bytevector 1 2) (bytevector 1 2))").should eq("#f")
  end
end

describe "bytevector access/mutation" do
  it "bytevector-length" do
    w("(bytevector-length (bytevector 1 2 3))").should eq("3")
  end

  it "bytevector-u8-ref/set!" do
    w("(bytevector-u8-ref (bytevector 10 20 30) 1)").should eq("20")
    w("(let ((bv (bytevector 1 2 3))) (bytevector-u8-set! bv 1 99) bv)").should eq("#u8(1 99 3)")
  end

  it "raises on out-of-range ref/set!" do
    expect_raises(Creme::SchemeRuntimeError, /index out of range/) { run("(bytevector-u8-ref (bytevector 1) 5)") }
    expect_raises(Creme::SchemeRuntimeError, /index out of range/) { run("(bytevector-u8-set! (bytevector 1) 5 0)") }
  end

  it "raises when setting a byte out of 0..255" do
    expect_raises(Creme::SchemeRuntimeError, /expected a byte/) { run("(bytevector-u8-set! (bytevector 1) 0 256)") }
  end
end

describe "bytevector-copy / bytevector-copy!" do
  it "copies a whole bytevector, or a range" do
    w("(bytevector-copy (bytevector 1 2 3))").should eq("#u8(1 2 3)")
    w("(bytevector-copy (bytevector 1 2 3) 1)").should eq("#u8(2 3)")
    w("(bytevector-copy (bytevector 1 2 3) 1 2)").should eq("#u8(2)")
  end

  it "copy is independent of the original" do
    w("(let* ((a (bytevector 1 2 3)) (b (bytevector-copy a))) (bytevector-u8-set! b 0 99) a)").should eq("#u8(1 2 3)")
  end

  it "bytevector-copy! mutates the destination at an offset" do
    w("(let ((dst (make-bytevector 5 0))) (bytevector-copy! dst 1 (bytevector 7 8 9)) dst)").should eq("#u8(0 7 8 9 0)")
  end

  it "raises when the destination is too small" do
    expect_raises(Creme::SchemeRuntimeError, /destination too small/) { run("(bytevector-copy! (make-bytevector 2) 0 (bytevector 1 2 3))") }
  end
end

describe "bytevector-append" do
  it "concatenates any number of bytevectors" do
    w("(bytevector-append (bytevector 1 2) (bytevector 3 4))").should eq("#u8(1 2 3 4)")
    w("(bytevector-append)").should eq("#u8()")
    w("(bytevector-append (bytevector 1))").should eq("#u8(1)")
  end
end

describe "utf8->string / string->utf8" do
  it "round-trips a string through UTF-8 bytes" do
    w(%[(utf8->string (string->utf8 "hello"))]).should eq(%("hello"))
  end

  it "supports a byte range" do
    w("(utf8->string (bytevector 72 105 33) 0 2)").should eq(%("Hi"))
  end

  it "raises for invalid UTF-8" do
    expect_raises(Creme::SchemeRuntimeError, /invalid UTF-8/) { run("(utf8->string (bytevector 255 254))") }
  end
end

describe "byte ports" do
  it "open-input-bytevector / read-u8 / peek-u8" do
    w(<<-SCM).should eq("(1 1 2 3 #t)")
      (define p (open-input-bytevector (bytevector 1 2 3)))
      (list (peek-u8 p) (read-u8 p) (read-u8 p) (read-u8 p) (eof-object? (read-u8 p)))
    SCM
  end

  it "open-output-bytevector / write-u8 / get-output-bytevector" do
    w(<<-SCM).should eq("#u8(65 66)")
      (define p (open-output-bytevector))
      (write-u8 65 p)
      (write-u8 66 p)
      (get-output-bytevector p)
    SCM
  end

  it "write-bytevector / read-bytevector round trip" do
    w(<<-SCM).should eq("#u8(1 2 3)")
      (define op (open-output-bytevector))
      (write-bytevector (bytevector 1 2 3) op)
      (get-output-bytevector op)
    SCM
    w(<<-SCM).should eq("#u8(1 2)")
      (read-bytevector 2 (open-input-bytevector (bytevector 1 2 3)))
    SCM
  end

  it "read-bytevector! reads into an existing bytevector and returns the count" do
    w(<<-SCM).should eq("(2 #u8(9 9 1 2 9))")
      (define dst (bytevector 9 9 9 9 9))
      (define n (read-bytevector! dst (open-input-bytevector (bytevector 1 2)) 2 4))
      (list n dst)
    SCM
  end

  it "u8-ready? reflects whether a byte is available" do
    w("(u8-ready? (open-input-bytevector (bytevector 1)))").should eq("#t")
    w("(u8-ready? (open-input-bytevector (bytevector)))").should eq("#f")
  end
end

describe "port predicates" do
  it "binary-port?/textual-port? distinguish byte vs string ports" do
    w("(binary-port? (open-input-bytevector (bytevector 1)))").should eq("#t")
    w("(textual-port? (open-input-bytevector (bytevector 1)))").should eq("#f")
    w(%[(binary-port? (open-input-string "hi"))]).should eq("#f")
    w(%[(textual-port? (open-input-string "hi"))]).should eq("#t")
  end

  it "input-port-open?/output-port-open? reflect closed state" do
    w(<<-SCM).should eq("#f")
      (define p (open-input-bytevector (bytevector 1)))
      (close-port p)
      (input-port-open? p)
    SCM
    w(%[(output-port-open? (open-output-string))]).should eq("#t")
  end

  it "char-ready? reflects data availability on an input port" do
    w(%[(char-ready? (open-input-string "hi"))]).should eq("#t")
    w(%[(char-ready? (open-input-string ""))]).should eq("#f")
  end
end

describe "call-with-port" do
  it "applies proc to the port and closes it afterward" do
    w(<<-SCM).should eq("(1 #f)")
      (define p (open-input-bytevector (bytevector 1)))
      (define result (call-with-port p read-u8))
      (list result (input-port-open? p))
    SCM
  end

  it "closes the port even if proc raises" do
    w(<<-SCM).should eq("#f")
      (define p (open-input-bytevector (bytevector 1)))
      (guard (e (#t 'ignored)) (call-with-port p (lambda (port) (error "boom"))))
      (input-port-open? p)
    SCM
  end
end
