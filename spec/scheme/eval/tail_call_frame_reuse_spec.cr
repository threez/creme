require "../../spec_helper"

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

# Covers the self-tail-recursive call-frame reuse optimization in
# eval_node.cr's AppNode/NamedLetNode arms: a closure-free lambda's own
# tail-recursive call reuses (mutates in place) its previous iteration's
# Env instead of allocating a fresh one every iteration. The dangerous
# failure mode is reusing a frame something else still needs — either a
# captured closure (corrupted bindings) or an ENCLOSING non-tail call still
# awaiting a sibling operand (corrupted values mid-computation, e.g. naive
# non-tail-recursive fib) — both are exercised here, not just the happy path.
describe "self-tail-recursive call-frame reuse" do
  it "still gives each closure captured inside a tail loop its own binding" do
    w(<<-SCM).should eq("(0 1 2 3 4)")
      (define (make-closures n)
        (let loop ((i 0) (acc '()))
          (if (= i n)
              (reverse acc)
              (loop (+ i 1) (cons (lambda () i) acc)))))
      (map (lambda (f) (f)) (make-closures 5))
    SCM
  end

  it "computes a plain closure-free named-let loop correctly" do
    w("(let loop ((i 0) (acc 0)) (if (= i 100000) acc (loop (+ i 1) (+ acc i))))")
      .should eq("4999950000")
  end

  it "computes a plain closure-free self-tail-recursive define correctly" do
    w(<<-SCM).should eq("5000050000")
      (define (sum-to n acc) (if (= n 0) acc (sum-to (- n 1) (+ acc n))))
      (sum-to 100000 0)
    SCM
  end

  it "does not corrupt bindings for NON-tail self-recursion (naive fib)" do
    # fib's recursive calls are arguments to `+`, not tail calls — every
    # activation of fib shares the same params array, so a shape-only check
    # would (and once did) wrongly treat this as safe to reuse, corrupting
    # `n` before the second recursive call reads it.
    w(<<-SCM).should eq("6765")
      (define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
      (fib 20)
    SCM
  end

  it "disables reuse once an internal define grows the loop's own frame" do
    w(<<-SCM).should eq("10")
      (define (loop-with-define n acc)
        (define extra 1)
        (if (= n 0) acc (loop-with-define (- n 1) (+ acc extra))))
      (loop-with-define 10 0)
    SCM
  end

  it "still lets call/cc escape a closure-free tail-recursive loop mid-iteration" do
    w(<<-SCM).should eq("7")
      (define (find-first n)
        (call/cc
         (lambda (return)
           (let loop ((i 0))
             (if (= i n)
                 #f
                 (if (= i 7)
                     (return i)
                     (loop (+ i 1))))))))
      (find-first 100)
    SCM
  end
end
