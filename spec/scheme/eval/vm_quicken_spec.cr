require "../../spec_helper"

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

# Covers VM#exec_call_global's own call-site quickening (Op::QCallGlobal*,
# opcode.cr) -- this VM's counterpart to icecreme/vm.c's OP_QCALLGLOBAL_* work
# (see doc/optimization-icecreme.md's "Call-site quickening" section), ported
# here since that mechanism never existed in the REAL production
# interpreter before: a still-generic Op::CallGlobal site whose resolved
# callee turns out to be one of +/-/*/cons/car/cdr gets rewritten in place
# (Chunk#requicken!) to a fused fast path, re-checked by identity on every
# later visit and deopted back to Op::CallGlobal the instant it fails.
#
# Every case here forces the call site to actually BE an Op::CallGlobal
# first (never Op::TailCallGlobal, which this mechanism deliberately never
# touches, same as icecreme's own scope -- every call below is used as a
# non-tail ARGUMENT, mirroring a self-recursive loop's own `(- n 1)` step,
# not the tail expression itself). The trickier part is defeating the
# native compiler's own static Op::Add/Sub/Mul/Cons/Cxr fusion correctly:
# unlike the self-hosted compiler (modules/creme/compiler/compiler.sld),
# which permanently disables fusion for a name for the rest of a compile
# the moment it sees ANY redefinition (mark-redefined!, see
# prim_call_spec.scm's own header comment), the NATIVE compiler's fusion
# (analyzer.cr's own AppNode arm) is a LIVE compile-time lookup of
# whatever the name is CURRENTLY bound to at the exact moment that
# specific call site is compiled -- it has no memory of past redefinitions
# at all. So the shadow must still be in effect WHILE the call site below
# is compiled (i.e. `set!` BEFORE the `define`), and the restore to the
# real builtin must happen AFTER that definition, not before it -- doing
# it in the opposite order (shadow, restore, then define) leaves the
# compiler seeing the ALREADY-restored real builtin at compile time and
# it fuses to Op::Add/etc regardless, so this mechanism's own code never
# even runs. Confirmed against this exact mistake during development: it
# doesn't fail loudly (a native Op::Add arm computes the same numeric
# result Op::QCallGlobalAdd2 would have, so wrong-order tests can still
# report correct VALUES) — it just means quickening silently never
# engages, only caught via a temporary requicken-count instrumentation,
# not by any test failing on its own.
describe "native VM call-site quickening (Op::QCallGlobal*)" do
  it "computes + correctly across many repeated calls (forces the runtime quicken to engage)" do
    w(<<-SCM).should eq("5000050000")
      (define real+ +)
      (set! + (lambda (a b) 'placeholder))
      (define (loop-add n acc) (if (= n 0) acc (loop-add (- n 1) (+ acc n))))
      (set! + real+)
      (loop-add 100000 0)
    SCM
  end

  it "computes -/*/cons/car/cdr correctly across many repeated calls" do
    w(<<-SCM).should eq("(-1000 1 (1 2 3 4 5) 1 (2 3 4 5))")
      (define real- -) (set! - (lambda (a b) 'placeholder))
      (define (loop-sub n acc) (if (= n 0) acc (loop-sub (- n 1) (- acc 1))))
      (set! - real-)

      (define real* *) (set! * (lambda (a b) 'placeholder))
      (define (loop-mul n acc) (if (= n 0) acc (loop-mul (- n 1) (* acc 1))))
      (set! * real*)

      (define real-cons cons) (set! cons (lambda (a b) 'placeholder))
      (define (loop-cons n p) (if (= n 0) p (loop-cons (- n 1) (cons n p))))
      (set! cons real-cons)

      (define real-car car) (set! car (lambda (p) 'placeholder))
      (define (pick-car p) (list (car p)))
      (set! car real-car)

      (define real-cdr cdr) (set! cdr (lambda (p) 'placeholder))
      (define (pick-cdr p) (list (cdr p)))
      (set! cdr real-cdr)

      (define built (loop-cons 5 '()))
      (list (loop-sub 1000 0) (loop-mul 1000 1) built (car (pick-car built)) (car (pick-cdr built)))
    SCM
  end

  it "deopts a quickened + call site to a runtime redefinition, and re-quickens once restored" do
    w(<<-SCM).should eq("(shadowed-plus 15)")
      (define real+ +)
      (set! + (lambda (a b) 'placeholder))
      (define (loop-add n acc) (if (= n 0) acc (loop-add (- n 1) (+ acc n))))
      (set! + real+)
      (loop-add 100000 0)
      (set! + (lambda (a b) 'shadowed-plus))
      (define shadowed-result (loop-add 1 0))
      (set! + real+)
      (list shadowed-result (loop-add 5 0))
    SCM
  end

  it "deopts a quickened car call site to a runtime redefinition, and re-quickens once restored" do
    w(<<-SCM).should eq("((shadowed-car) (9))")
      (define real-car car)
      (set! car (lambda (p) 'placeholder))
      (define (pick-car p) (list (car p)))
      (set! car real-car)
      (pick-car (cons 1 2))
      (set! car (lambda (p) 'shadowed-car))
      (define shadowed-result (pick-car (cons 9 8)))
      (set! car real-car)
      (list shadowed-result (pick-car (cons 9 8)))
    SCM
  end

  it "deopts a quickened cons call site to redefinition with a genuine Scheme closure (not another builtin), and re-quickens once restored" do
    w(<<-SCM).should eq("((wrapped 1 ()) (1))")
      (define real-cons cons)
      (set! cons (lambda (a b) 'placeholder))
      (define (loop-cons n p) (if (= n 0) p (loop-cons (- n 1) (cons n p))))
      (set! cons real-cons)
      (loop-cons 1 '())
      (set! cons (lambda (a b) (list 'wrapped a b)))
      (define shadowed-result (loop-cons 1 '()))
      (set! cons real-cons)
      (list shadowed-result (loop-cons 1 '()))
    SCM
  end

  it "still raises on a wrong-type argument, both before and after the call site has quickened" do
    w(<<-SCM).should eq("(raised raised)")
      (define real-car car)
      (set! car (lambda (p) 'placeholder))
      (define (safe-car p) (guard (e (#t 'raised)) (list (car p))))
      (set! car real-car)
      (define first-try (safe-car 5))
      (safe-car (cons 1 2))
      (safe-car (cons 3 4))
      (define second-try (safe-car 5))
      (list first-try second-try)
    SCM
  end
end
