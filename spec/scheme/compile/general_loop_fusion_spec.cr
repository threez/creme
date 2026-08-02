require "../../spec_helper"

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

# Compiles `src` (a single top-level `define` whose body is the loop under
# test) and returns that define's own Chunk directly, bypassing running it
# — for asserting on the COMPILED SHAPE (no nested Op::Closure for the
# loop procedure), not just the computed value. Mirrors BytecodeCompiler.
# run_program's own analyze-then-compile_program pairing (bytecode_
# compiler.cr), just stopping before the VM.run step.
private def compile_define(src : String) : Creme::Chunk
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  form = Creme.forms_for(interp, src, "spec").first
  node = interp.analyze(form, interp.global)
  chunk = Creme::BytecodeCompiler.compile_program([node])
  chunk.protos.first
end

# Covers try_compile_general_loop/detect_general_loop_shape(_cond)
# (bytecode_compiler.cr) — the non-counted-loop generalization of the
# existing try_compile_counted_loop/detect_counted_loop_shape: a named-
# let/do that self-tail-recurses WITHOUT a numeric counter (e.g. walking a
# list via `(cdr ...)`) still lowers to plain mutable registers instead of
# allocating a fresh Closure every time its enclosing function runs, the
# same way a counted loop already does — see doc/optimization-cvm.md and
# the investigation that motivated this (hashtable-test's own `scan`,
# competition/bench/workloads.scm, closes over its own `k` and got a fresh
# Closure on every single lookup call before this).
#
# NOTE: this is a NATIVE-compiler-only optimization so far — it has not
# been ported to the self-hosted compiler (modules/creme/compiler/
# compiler.sld) the way the counted-loop work eventually was (see that
# work's own doc/optimization-general.md account) — so cvm and
# --self-hosted still allocate a real closure for these shapes today.
# should-match-native?-style cross-backend value comparisons (creme-spec-
# cvm) still pass regardless, since this only changes WHICH bytecode path
# computes a value, never the value itself.
describe "general (non-counted) loop closure elimination" do
  it "still computes correctly for the exact motivating shape (a cond-based assoc scan, closing over its own key)" do
    w(<<-SCM).should eq("(50 190 0)")
      (define (make-alist n) (let loop ((i 1) (acc '())) (if (= i n) acc (loop (+ i 1) (cons (cons i (* i 10)) acc)))))
      (define (assoc-scan k alist)
        (let scan ((entries alist))
          (cond ((null? entries) 0)
                ((= (caar entries) k) (cdar entries))
                (else (scan (cdr entries))))))
      (define al (make-alist 20))
      (list (assoc-scan 5 al) (assoc-scan 19 al) (assoc-scan 999 al))
    SCM
  end

  it "no longer allocates a nested Closure for that motivating shape" do
    chunk = compile_define(<<-SCM)
      (define (assoc-scan k alist)
        (let scan ((entries alist))
          (cond ((null? entries) 0)
                ((= (caar entries) k) (cdar entries))
                (else (scan (cdr entries))))))
    SCM
    chunk.protos.should be_empty
    chunk.instructions.none? { |i| i.op == Creme::Op::Closure }.should be_true
  end

  it "computes correctly with no accumulator (for-each style, walking cdr)" do
    w(<<-SCM).should eq("5")
      (define (count-list lst)
        (let loop ((l lst) (n 0))
          (if (null? l) n (loop (cdr l) (+ n 1)))))
      (count-list '(a b c d e))
    SCM
  end

  it "no longer allocates a nested Closure for the no-accumulator shape" do
    chunk = compile_define(<<-SCM)
      (define (count-list lst)
        (let loop ((l lst) (n 0))
          (if (null? l) n (loop (cdr l) (+ n 1)))))
    SCM
    chunk.protos.should be_empty
    chunk.instructions.none? { |i| i.op == Creme::Op::Closure }.should be_true
  end

  it "computes correctly with multiple loop-carried values and no counter at all" do
    w(<<-SCM).should eq("((2 4 6 8 10) (1 3 5 7 9))")
      (define (split-evens-odds lst)
        (let loop ((l lst) (evens '()) (odds '()))
          (if (null? l)
              (list (reverse evens) (reverse odds))
              (if (even? (car l))
                  (loop (cdr l) (cons (car l) evens) odds)
                  (loop (cdr l) evens (cons (car l) odds))))))
      (split-evens-odds '(1 2 3 4 5 6 7 8 9 10))
    SCM
  end

  it "computes correctly when step expressions cross-reference each other's OLD values (needs_temp path)" do
    w(<<-SCM).should eq("(second first)")
      (define (swap-walk lst a b)
        (let loop ((l lst) (a a) (b b))
          (if (null? l) (list a b) (loop (cdr l) b a))))
      (swap-walk '(x y z) 'first 'second)
    SCM
  end

  it "computes correctly with an early return in the recurse-in-conseq position" do
    w(<<-SCM).should eq("(6 #f)")
      (define (find-first pred lst)
        (let loop ((l lst))
          (if (null? l)
              #f
              (if (pred (car l)) (car l) (loop (cdr l))))))
      (list (find-first even? '(1 3 5 6 7)) (find-first even? '(1 3 5 7)))
    SCM
  end

  it "still gives each closure captured inside the loop its own binding (escape check isn't over-eager)" do
    w(<<-SCM).should eq("(4 3 2 1 0)")
      (define (make-escaping-loop n)
        (let loop ((i 0) (acc '()))
          (if (= i n)
              (lambda () acc)
              (loop (+ i 1) (cons (lambda () i) acc)))))
      (map (lambda (f) (f)) ((make-escaping-loop 5)))
    SCM
  end

  it "the escaping-loop shape still allocates a real Closure (the escape check correctly declines)" do
    chunk = compile_define(<<-SCM)
      (define (make-escaping-loop n)
        (let loop ((i 0) (acc '()))
          (if (= i n)
              (lambda () acc)
              (loop (+ i 1) (cons (lambda () i) acc)))))
    SCM
    chunk.instructions.any? { |i| i.op == Creme::Op::Closure }.should be_true
  end

  it "computes correctly for the equivalent do-loop shape" do
    w(<<-SCM).should eq("6")
      (define (count-list-do lst)
        (do ((l lst (cdr l)) (n 0 (+ n 1)))
            ((null? l) n)))
      (count-list-do '(a b c d e f))
    SCM
  end

  it "no longer allocates a nested Closure for the do-loop shape" do
    chunk = compile_define(<<-SCM)
      (define (count-list-do lst)
        (do ((l lst (cdr l)) (n 0 (+ n 1)))
            ((null? l) n)))
    SCM
    chunk.protos.should be_empty
    chunk.instructions.none? { |i| i.op == Creme::Op::Closure }.should be_true
  end

  it "computes correctly at a larger scale (matching hashtable-test's own order of magnitude)" do
    w(<<-SCM).should eq("499500")
      (define (build-chain n) (let loop ((i 0) (acc '())) (if (= i n) acc (loop (+ i 1) (cons i acc)))))
      (define (sum-via-cdr-walk lst) (let loop ((l lst) (acc 0)) (if (null? l) acc (loop (cdr l) (+ acc (car l))))))
      (sum-via-cdr-walk (build-chain 1000))
    SCM
  end
end
