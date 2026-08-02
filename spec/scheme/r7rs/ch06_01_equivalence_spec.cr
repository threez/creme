require "../../spec_helper"

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "R7RS §6.1 Equivalence predicates (eqv?)" do
  it "is #t for identical booleans, symbols, exact numerically-equal numbers, and ()" do
    w("(eqv? 'a 'a)").should eq("#t")
    w("(eqv? 2 2)").should eq("#t")
    w("(eqv? '() '())").should eq("#t")
    w("(eqv? 100000000 100000000)").should eq("#t")
  end

  it "is #f for an exact and an inexact number even if numerically equal, and for freshly-cons'd pairs" do
    w("(eqv? 2 2.0)").should eq("#f")
    w("(eqv? (cons 1 2) (cons 1 2))").should eq("#f")
  end

  it "is #f for different-bodied lambdas, and unspecified for identically-bodied ones" do
    w("(eqv? (lambda () 1) (lambda () 2))").should eq("#f")
  end

  it "recognizes a procedure as eqv? to itself" do
    w("(define p (lambda (x) x)) (eqv? p p)").should eq("#t")
  end

  it "distinguishes procedures with distinct captured state (gen-counter) but may conflate operationally-equivalent ones (gen-loser)" do
    w(<<-SCM).should eq("#t")
      (define (gen-counter)
        (let ((n 0)) (lambda () (set! n (+ n 1)) n)))
      (define g (gen-counter))
      (eqv? g g)
    SCM
    w("(define (gen-counter) (let ((n 0)) (lambda () (set! n (+ n 1)) n))) (eqv? (gen-counter) (gen-counter))").should eq("#f")
  end

  it "(eqv? 0.0 -0.0) is #f, since negative zero is distinguished from positive zero" do
    w("(eqv? 0.0 -0.0)").should eq("#f")
  end
end

describe "R7RS §6.1 Equivalence predicates (eq?)" do
  it "is guaranteed consistent with eqv? on symbols, booleans, (), pairs, records, non-empty strings/vectors/bytevectors" do
    w("(eq? 'a 'a)").should eq("#t")
    w("(eq? '() '())").should eq("#t")
    w("(let ((x '(a))) (eq? x x))").should eq("#t")
  end

  it "returns #t for the same procedure object" do
    w("(eq? car car)").should eq("#t")
  end
end

describe "R7RS §6.1 Equivalence predicates (equal?)" do
  it "recursively compares pairs/vectors/strings/bytevectors as ordered trees" do
    w("(equal? 'a 'a)").should eq("#t")
    w("(equal? '(a (b) c) '(a (b) c))").should eq("#t")
    w(%[(equal? "abc" "abc")]).should eq("#t")
    w("(equal? 2 2)").should eq("#t")
    w("(equal? (make-vector 5 'a) (make-vector 5 'a))").should eq("#t")
  end

  it "falls back to eqv?'s behavior for booleans/symbols/numbers/characters/ports/procedures/the empty list" do
    w("(equal? car car)").should eq("#t")
    w("(equal? #t #t)").should eq("#t")
  end

  it "terminates even on circular data structures, comparing equal circular lists as equal" do
    w(<<-SCM).should eq("#t")
      (define a (list 1 2))
      (set-cdr! (cdr a) a)
      (define b (list 1 2))
      (set-cdr! (cdr b) b)
      (equal? a b)
    SCM
  end

  it "terminates on circular structures with differing content, correctly comparing them unequal" do
    w(<<-SCM).should eq("#f")
      (define a (list 1 2))
      (set-cdr! (cdr a) a)
      (define b (list 1 3))
      (set-cdr! (cdr b) b)
      (equal? a b)
    SCM
  end
end
