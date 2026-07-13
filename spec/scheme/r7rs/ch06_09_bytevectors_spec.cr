require "../../spec_helper"

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "R7RS §6.9 Bytevectors" do
  it "bytevector? is #t for bytevector objects" do
    w("(bytevector? #u8(1 2 3))").should eq("#t")
    w("(bytevector? (vector 1 2 3))").should eq("#f")
  end

  it "write produces R7RS's #u8(byte ...) external representation for bytevectors" do
    w("(bytevector 1 2 3)").should eq("#u8(1 2 3)")
  end

  it "make-bytevector returns a newly allocated bytevector of k elements, optionally initialized to byte" do
    w("(bytevector-length (make-bytevector 2 12))").should eq("2")
    w("(bytevector-u8-ref (make-bytevector 2 12) 0)").should eq("12")
  end

  it "bytevector returns a newly allocated bytevector containing its byte arguments" do
    w("(bytevector-length (bytevector 1 3 5 1 3 5))").should eq("6")
    w("(bytevector-u8-ref (bytevector 1 3 5 1 3 5) 2)").should eq("5")
  end

  it "bytevector-length returns the number of bytes" do
    w("(bytevector-length #u8(1 2 3))").should eq("3")
  end

  it "bytevector-u8-ref returns the kth byte" do
    w("(bytevector-u8-ref '#u8(1 1 2 3 5 8 13 21) 5)").should eq("8")
  end

  it "bytevector-u8-set! stores byte as the kth byte" do
    w(<<-SCM).should eq("3")
      (define bv (bytevector 1 2 3 4))
      (bytevector-u8-set! bv 1 3)
      (bytevector-u8-ref bv 1)
    SCM
  end

  it "bytevector-copy returns a newly allocated bytevector containing the given byte range" do
    w(<<-SCM).should eq("(3 4)")
      (define bv (bytevector-copy #u8(1 2 3 4 5) 2 4))
      (list (bytevector-u8-ref bv 0) (bytevector-u8-ref bv 1))
    SCM
  end

  it "bytevector-copy! copies a range of bytes from one bytevector into another at a given offset" do
    w(<<-SCM).should eq("(1 10 20 4 5)")
      (define bv (bytevector 1 2 3 4 5))
      (bytevector-copy! bv 1 (bytevector 10 20 30 40 50) 0 2)
      (list (bytevector-u8-ref bv 0) (bytevector-u8-ref bv 1) (bytevector-u8-ref bv 2) (bytevector-u8-ref bv 3) (bytevector-u8-ref bv 4))
    SCM
  end

  it "bytevector-append returns a newly allocated concatenation of its bytevector arguments" do
    w(<<-SCM).should eq("(0 1 2 3 4 5)")
      (define bv (bytevector-append #u8(0 1 2) #u8(3 4 5)))
      (list (bytevector-u8-ref bv 0) (bytevector-u8-ref bv 1) (bytevector-u8-ref bv 2)
            (bytevector-u8-ref bv 3) (bytevector-u8-ref bv 4) (bytevector-u8-ref bv 5))
    SCM
  end

  it "utf8->string/string->utf8 translate between a bytevector and a string via UTF-8" do
    w("(utf8->string #u8(65))").should eq(%("A"))
  end
end
