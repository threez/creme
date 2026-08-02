require "../../spec_helper"

# Hand-assembles Chunks that use Op::ForPrep/Op::ForLoop directly — no
# compiler pass emits these yet (see bytecode_compiler.cr's compile_named_let/
# compile_do), so this exercises the two opcodes' VM semantics in isolation
# ahead of/independent from whatever recognizer eventually lowers a counted
# `let loop`/`do` into them. Mirrors main.cr's dump_bytecode's own
# `Creme::VM.new(interp, interp.global).run(chunk)` pattern for running a
# freestanding Chunk.
private def run_chunk(chunk : Creme::Chunk) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme::VM.new(interp, interp.global).run(chunk)
end

# Builds a chunk computing `sum(counter=start; counter cmp limit; counter +=
# step) counter` (an accumulator register `acc`, register 0) the same shape
# every ForPrep/ForLoop-lowered counted loop would use: reg 0 = acc, reg 1 =
# counter, reg 2 = limit.
private def counted_sum_chunk(start : Int32, limit : Int32, step : Int32) : Creme::Chunk
  chunk = Creme::Chunk.new
  chunk.num_registers = 3
  acc, counter, lim = 0, 1, 2
  chunk.emit(Creme::Op::LoadK, acc, chunk.consts.size)
  chunk.consts << Creme::SchemeInt.new(0_i64)
  chunk.emit(Creme::Op::LoadK, counter, chunk.consts.size)
  chunk.consts << Creme::SchemeInt.new(start.to_i64)
  chunk.emit(Creme::Op::LoadK, lim, chunk.consts.size)
  chunk.consts << Creme::SchemeInt.new(limit.to_i64)

  prep_ip = chunk.emit(Creme::Op::ForPrep, counter, 0, lim, step)
  body_start = chunk.instructions.size
  chunk.emit(Creme::Op::Add, acc, acc, counter)
  loop_ip = chunk.emit(Creme::Op::ForLoop, counter, 0, lim, step)
  chunk.instructions[loop_ip] = Creme::Instruction.new(
    Creme::Op::ForLoop, counter, body_start - (loop_ip + 1), lim, step
  )
  chunk.patch_jump_to_here(prep_ip)
  chunk.emit(Creme::Op::Return, acc)
  chunk
end

describe "Op::ForPrep / Op::ForLoop" do
  # Range is INCLUSIVE of limit (Lua FORLOOP-style — see opcode.cr's doc
  # comment), so 0..5 step 1 visits 0,1,2,3,4,5.
  it "sums an inclusive ascending range (0..5 step 1)" do
    run_chunk(counted_sum_chunk(0, 5, 1)).write_string.should eq("15")
  end

  it "sums an inclusive ascending range with a step > 1 (0..10 step 2)" do
    run_chunk(counted_sum_chunk(0, 10, 2)).write_string.should eq("30")
  end

  it "sums an inclusive descending range (5..0 step -1)" do
    run_chunk(counted_sum_chunk(5, 0, -1)).write_string.should eq("15")
  end

  it "never enters the loop body when start is already past the limit" do
    run_chunk(counted_sum_chunk(6, 5, 1)).write_string.should eq("0")
    run_chunk(counted_sum_chunk(-1, 0, -1)).write_string.should eq("0")
  end

  it "runs exactly the boundary iteration when start equals limit" do
    run_chunk(counted_sum_chunk(5, 5, 1)).write_string.should eq("5")
  end
end

# try_compile_global_counted_loop (bytecode_compiler.cr) — the ordinary
# self-recursive `(define (f params...) body)` counterpart of try_compile_
# counted_loop, lowering to Op::ForLoopGuardedInc/Dec + Op::TestGlobalIdentity
# instead of the plain Op::ForLoop, since `f`'s own name is a mutable GLOBAL
# (see those opcodes' own doc comments in opcode.cr for the full mechanism).
private def run_program(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  forms = Creme::Reader.read_all(src)
  Creme::BytecodeCompiler.run_program(interp, forms)
end

# Analyzes+compiles every given top-level form in order (against a fresh
# Interpreter with (scheme base) already imported, matching main.cr's
# dump_bytecode's own auto-import-for-inspection default), running each one
# as it goes (so an earlier `(define LIMIT ...)` is genuinely bound by the
# time a later self-recursive define's own body is analyzed) — the same
# per-form loop run_program uses — and returns the LAST form's own proto
# instructions, i.e. what compile_lambda emitted for its body, so a spec
# can assert on the actual opcodes chosen without needing its own
# disassembler.
private def compiled_body_ops(src : String) : Array(Creme::Op)
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base))")
  forms = Creme::Reader.read_all(src)
  chunk = Creme::Chunk.new
  forms.each do |form|
    node = interp.analyze(form, interp.global)
    chunk = Creme::BytecodeCompiler.compile_program([node])
    Creme::VM.new(interp, interp.global).run(chunk)
  end
  chunk.protos.first.instructions.map(&.op)
end

describe "self-recursive global counted-loop fusion" do
  it "fuses a plain tail-recursive accumulator define (decrementing counter)" do
    run_program("(define (sum-to n acc) (if (= n 0) acc (sum-to (- n 1) (+ acc n)))) (sum-to 100000 0)")
      .write_string.should eq("5000050000")
    compiled_body_ops("(define (sum-to n acc) (if (= n 0) acc (sum-to (- n 1) (+ acc n))))")
      .should contain(Creme::Op::ForLoopGuardedDec)
  end

  it "fuses an incrementing counted self-recursive define" do
    # The bound must be a genuinely loop-invariant expression, not one of the loop's
    # OWN params (detect_counted_loop_shape's hard requirement, shared with try_compile_
    # counted_loop — see its own doc comment) — a global constant, unlike a 3rd
    # parameter, can't vary per-call, so it qualifies.
    src = "(define LIMIT 100000) (define (count-up i acc) (if (= i LIMIT) acc (count-up (+ i 1) (+ acc i)))) (count-up 0 0)"
    run_program(src).write_string.should eq("4999950000")
    compiled_body_ops("(define LIMIT 100000) (define (count-up i acc) (if (= i LIMIT) acc (count-up (+ i 1) (+ acc i))))")
      .should contain(Creme::Op::ForLoopGuardedInc)
  end

  it "does NOT fuse a step other than +-1 (falls back to the ordinary TailCallGlobal path unchanged)" do
    ops = compiled_body_ops("(define (sum-by-2 n acc) (if (= n 0) acc (sum-by-2 (- n 2) (+ acc n))))")
    ops.should_not contain(Creme::Op::ForLoopGuardedDec)
    ops.should contain(Creme::Op::TailCallGlobal)
    run_program("(define (sum-by-2 n acc) (if (= n 0) acc (sum-by-2 (- n 2) (+ acc n)))) (sum-by-2 100000 0)")
      .write_string.should eq("2500050000")
  end

  it "does NOT fuse an internal (non-global) self-recursive define" do
    ops = compiled_body_ops(<<-SCM)
      (define (outer)
        (define (sum-to n acc) (if (= n 0) acc (sum-to (- n 1) (+ acc n))))
        (sum-to 100000 0))
    SCM
    ops.should_not contain(Creme::Op::ForLoopGuardedDec)
  end

  it "produces the exact same result whether or not the global is redefined mid-loop, deopting correctly" do
    # Redefines `sum-to` itself partway through a long loop (at n == 5,000,000, well
    # after the fast guarded loop would have started) to a totally different function —
    # the fused loop must detect this every iteration and hand off to the NEW binding
    # for the remainder, exactly like the unoptimized TailCallGlobal path always would.
    src = <<-SCM
      (define (sum-to n acc)
        (if (= n 5000000)
            (begin (set! sum-to (lambda (n acc) (+ 999999 n acc))) (sum-to (- n 1) (+ acc n)))
            (if (= n 0) acc (sum-to (- n 1) (+ acc n)))))
      (sum-to 10000000 0)
    SCM
    run_program(src).write_string.should eq("37500013499998")
  end

  it "still produces the correct result when the global is redefined to an equivalent counted-loop-shaped function" do
    # A subtler redefinition than "swap in something unrelated": the new binding is
    # ITSELF a fusable counted loop. The deopt must still hand off correctly (the NEW
    # closure's own compiled body — its own fresh ForLoopGuardedDec loop — takes over)
    # rather than silently continuing to iterate against the OLD closure.
    src = <<-SCM
      (define (sum-to n acc)
        (if (= n 999900)
            (begin
              (set! sum-to (lambda (n acc) (if (= n 0) (+ acc 1000000) (sum-to (- n 1) (+ acc n)))))
              (sum-to (- n 1) (+ acc n)))
            (if (= n 0) acc (sum-to (- n 1) (+ acc n)))))
      (sum-to 1000000 0)
    SCM
    run_program(src).write_string.should eq("500001500000")
  end
end
