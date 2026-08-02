require "../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (creme for)) #{src}").write_string
end

describe "for module" do
  describe "in-range/in-list/in-vector/in-string" do
    it "in-range supports 1/2/3-arg forms, including a negative step" do
      w("(in-range 5)").should eq("(0 1 2 3 4)")
      w("(in-range 2 5)").should eq("(2 3 4)")
      w("(in-range 2 10 3)").should eq("(2 5 8)")
      w("(in-range 10 0 -2)").should eq("(10 8 6 4 2)")
      w("(in-range 3 3)").should eq("()")
    end

    it "in-list/in-vector/in-string return plain lists" do
      w("(in-list '(1 2 3))").should eq("(1 2 3)")
      w("(in-vector (vector 1 2 3))").should eq("(1 2 3)")
      w("(in-string \"ab\")").should eq("(#\\a #\\b)")
    end
  end

  describe "for/for-list" do
    it "for/list collects results, for runs purely for side effects" do
      w("(for/list ((x (in-list '(1 2 3)))) (* x x))").should eq("(1 4 9)")
      w(<<-SCHEME).should eq("6")
        (define total 0)
        (for ((x (in-list '(1 2 3)))) (set! total (+ total x)))
        total
        SCHEME
    end

    it "zips multiple clauses in parallel, stopping at the shortest" do
      w("(for/list ((x (in-list '(1 2 3))) (y (in-list '(10 20 30)))) (+ x y))").should eq("(11 22 33)")
      w("(for/list ((x (in-list '(1 2 3))) (y (in-list '(10 20)))) (+ x y))").should eq("(11 22)")
    end
  end

  it "for/vector collects into a vector" do
    w("(for/vector ((x (in-range 5))) (* x x))").should eq("#(0 1 4 9 16)")
  end

  it "for/sum and for/product accumulate with + and *" do
    w("(for/sum ((x (in-range 1 6))) x)").should eq("15")
    w("(for/product ((x (in-range 1 5))) x)").should eq("24")
  end

  describe "for/and and for/or" do
    it "matches SRFI-1 every/any-style return values" do
      w("(for/and ((x (in-list '(2 4 6)))) (even? x))").should eq("#t")
      w("(for/and ((x (in-list '(2 4 5 6)))) (even? x))").should eq("#f")
      w("(for/or ((x (in-list '(1 3 5 6)))) (and (even? x) x))").should eq("6")
      w("(for/or ((x (in-list '(1 3 5)))) (and (even? x) x))").should eq("#f")
    end

    it "short-circuits without evaluating body past the deciding element" do
      w(<<-SCHEME).should eq("#f")
        (for/and ((x (in-list '(1 2 3 4))))
          (if (> x 2) (error "should not reach") (< x 2)))
        SCHEME
      w(<<-SCHEME).should eq("#t")
        (for/or ((x (in-list '(1 2 3 4))))
          (if (> x 2) (error "should not reach") (> x 1)))
        SCHEME
    end
  end

  describe "for/first and for/last" do
    it "for/first returns only the first combination's result" do
      w("(for/first ((x (in-list '(1 2 3)))) (* x 100))").should eq("100")
      w("(for/first ((x (in-list '()))) x)").should eq("#f")
    end

    it "for/last returns the last combination's result" do
      w("(for/last ((x (in-list '(1 2 3)))) (* x 100))").should eq("300")
      w("(for/last ((x (in-list '()))) x)").should eq("#f")
    end
  end

  describe "for/fold" do
    it "threads a single accumulator" do
      w("(for/fold ((acc 0)) ((x (in-range 1 6))) (+ acc x))").should eq("15")
    end

    it "threads multiple accumulators via (values ...)" do
      w(<<-SCHEME).should eq("(1 9)")
        (call-with-values
          (lambda ()
            (for/fold ((mn 9999) (mx -9999))
                      ((x (in-list '(3 1 4 1 5 9 2 6))))
              (values (min mn x) (max mx x))))
          list)
        SCHEME
    end
  end

  it "for/alist builds a (key . value) alist in iteration order" do
    w("(for/alist ((x (in-list '(a b c))) (i (in-range 3))) (values x i))").should eq("((a . 0) (b . 1) (c . 2))")
  end

  describe "for* and for*/list" do
    it "for*/list produces the full Cartesian product in row-major order" do
      w("(for*/list ((x (in-list '(1 2))) (y (in-list '(10 20)))) (+ x y))").should eq("(11 21 12 22)")
    end

    it "for* runs the full Cartesian product purely for side effects" do
      w(<<-SCHEME).should eq("((1 a) (1 b) (2 a) (2 b))")
        (let ((acc '()))
          (for* ((x (in-list '(1 2))) (y (in-list '(a b))))
            (set! acc (cons (list x y) acc)))
          (reverse acc))
        SCHEME
    end
  end
end
