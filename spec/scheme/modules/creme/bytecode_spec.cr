require "../../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (creme bytecode)) #{src}").write_string
end

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (creme bytecode)) #{src}")
end

describe "bytecode module" do
  it "looks up every opcode's ordinal, in Op enum declaration order" do
    w(%((op-ordinal 'LoadK))).should eq("0")
    w(%((op-ordinal 'SetGlobal))).should eq("9")
    w(%((op-ordinal 'Call))).should eq("87")
    w(%((op-ordinal 'Closure))).should eq("107")
    w(%((op-ordinal 'HelperFormLocal))).should eq("118")
  end

  it "raises clearly on an unknown opcode name" do
    expect_raises(Creme::SchemeRuntimeError, /unknown opcode/) do
      run(%((op-ordinal 'NotARealOp)))
    end
  end

  it "builds, patches, and serializes a chunk that runs correctly via load-chunk-bytes" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    Creme.run_source(interp, "(import (creme bytecode) (creme bootstrap))")
    # (lambda () (if #f 1 2)) inlined as a top-level chunk: LoadFalse-free —
    # load a boolean const, test it, jump over the "then" branch.
    src = <<-SCM
    (define ch (make-chunk "test"))
    (define test-reg 0)
    (define dest 1)
    (chunk-num-registers-set! ch 2)
    (chunk-emit! ch 'LoadK test-reg (chunk-add-const! ch #f) 0 0)
    (define jmp-false (chunk-emit! ch 'TestFalse test-reg 0 0 0))
    (chunk-emit! ch 'LoadK dest (chunk-add-const! ch 111) 0 0)
    (define jmp-end (chunk-emit! ch 'Jmp 0 0 0 0))
    (chunk-patch-jump-to-here! ch jmp-false)
    (chunk-emit! ch 'LoadK dest (chunk-add-const! ch 222) 0 0)
    (chunk-patch-jump-to-here! ch jmp-end)
    (chunk-emit! ch 'Return dest 0 0 0)
    (load-chunk-bytes (chunk->bytes ch))
    SCM
    Creme.run_source(interp, src).write_string.should eq("222")
  end

  it "round-trips a chunk with a closure, upvalue capture, and a proto" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    Creme.run_source(interp, "(import (creme bytecode) (creme bootstrap))")
    # Hand-builds the equivalent of:
    #   (define (make-adder n) (lambda (x) (+ x n)))
    #   ((make-adder 5) 10)
    # across three chunks (program -> make-adder -> the returned lambda),
    # to exercise Closure/GetUpval/proto/upvalue bookkeeping directly
    # through this library's own API rather than via the compiler.
    src = <<-SCM
    (define inner (make-chunk "adder"))
    (chunk-param-count-set! inner 1)
    (chunk-num-registers-set! inner 4)
    (define n-up (chunk-add-upval! inner 'n #t 0))
    (chunk-emit! inner 'GetGlobal 1 (chunk-add-const! inner '+) 0 0)
    (chunk-emit! inner 'Move 2 0 0 0)
    (chunk-emit! inner 'GetUpval 3 n-up 0 0)
    (chunk-emit! inner 'TailCall 1 2 0 0)

    (define outer (make-chunk "make-adder"))
    (chunk-param-count-set! outer 1)
    (chunk-num-registers-set! outer 2)
    (define inner-proto-idx (chunk-add-proto! outer inner))
    (chunk-emit! outer 'Closure 1 inner-proto-idx 0 0)
    (chunk-emit! outer 'Return 1 0 0 0)

    (define program (make-chunk "program"))
    (chunk-num-registers-set! program 7)
    (define outer-proto-idx (chunk-add-proto! program outer))
    (chunk-emit! program 'Closure 0 outer-proto-idx 0 0)
    (chunk-emit! program 'DefGlobal (chunk-add-const! program 'make-adder) 0 0 0)
    (chunk-emit! program 'GetGlobal 1 (chunk-add-const! program 'make-adder) 0 0)
    (chunk-emit! program 'LoadK 2 (chunk-add-const! program 5) 0 0)
    (chunk-emit! program 'Call 1 1 3 0)
    (chunk-emit! program 'Move 4 3 0 0)
    (chunk-emit! program 'LoadK 5 (chunk-add-const! program 10) 0 0)
    (chunk-emit! program 'Call 4 1 6 0)
    (chunk-emit! program 'Return 6 0 0 0)

    (load-chunk-bytes (chunk->bytes program))
    SCM
    Creme.run_source(interp, src).write_string.should eq("15")
  end
end
