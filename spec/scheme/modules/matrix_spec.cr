require "../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (scheme base) (creme matrix)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (scheme base) (creme matrix)) #{src}")
end

describe "matrix module" do
  it "builds from rows and reports dimensions" do
    w("(let ((m (matrix '(1 2 3) '(4 5 6)))) (list (matrix-rows m) (matrix-cols m)))").should eq("(2 3)")
  end

  it "reads and writes elements" do
    w("(matrix-ref (matrix '(1 2) '(3 4)) 1 0)").should eq("3")
  end

  it "matrix-set! mutates in place" do
    w(<<-SCHEME).should eq("9")
      (define m (matrix '(1 2) '(3 4)))
      (matrix-set! m 1 1 9)
      (matrix-ref m 1 1)
      SCHEME
  end

  it "extracts a row and a column" do
    w("(vector->list (matrix-row (matrix '(1 2 3) '(4 5 6)) 0))").should eq("(1 2 3)")
    w("(vector->list (matrix-column (matrix '(1 2 3) '(4 5 6)) 1))").should eq("(2 5)")
  end

  it "builds an identity matrix" do
    w("(matrix->list (matrix-identity 3))").should eq("((1 0 0) (0 1 0) (0 0 1))")
  end

  it "builds a zero matrix" do
    w("(matrix->list (matrix-zero 2 3))").should eq("((0 0 0) (0 0 0))")
  end

  it "adds and subtracts elementwise" do
    w("(matrix->list (matrix-add (matrix '(1 2)) (matrix '(3 4))))").should eq("((4 6))")
    w("(matrix->list (matrix-sub (matrix '(5 5)) (matrix '(1 2))))").should eq("((4 3))")
  end

  it "raises on dimension mismatch for add" do
    expect_raises(Scheme::SchemeError) { run("(matrix-add (matrix '(1 2)) (matrix '(1 2 3)))") }
  end

  it "scales every element" do
    w("(matrix->list (matrix-scale (matrix '(1 2) '(3 4)) 2))").should eq("((2 4) (6 8))")
  end

  it "multiplies matrices" do
    w("(matrix->list (matrix-multiply (matrix '(1 2) '(3 4)) (matrix '(5 6) '(7 8))))")
      .should eq("((19 22) (43 50))")
  end

  it "raises on dimension mismatch for multiply" do
    expect_raises(Scheme::SchemeError) { run("(matrix-multiply (matrix '(1 2)) (matrix '(1 2)))") }
  end

  it "transposes" do
    w("(matrix->list (matrix-transpose (matrix '(1 2 3) '(4 5 6))))").should eq("((1 4) (2 5) (3 6))")
  end

  it "computes the trace of a square matrix" do
    w("(matrix-trace (matrix '(1 2) '(3 4)))").should eq("5")
  end

  it "computes a 2x2 determinant" do
    w("(matrix-determinant (matrix '(1 2) '(3 4)))").should eq("-2")
  end

  it "computes a 3x3 determinant via cofactor expansion" do
    w("(matrix-determinant (matrix '(6 1 1) '(4 -2 5) '(2 8 7)))").should eq("-306")
  end

  it "raises when determinant is asked of a non-square matrix" do
    expect_raises(Scheme::SchemeError) { run("(matrix-determinant (matrix '(1 2 3) '(4 5 6)))") }
  end

  it "checks matrix equality" do
    w("(matrix-equal? (matrix '(1 2) '(3 4)) (matrix '(1 2) '(3 4)))").should eq("#t")
    w("(matrix-equal? (matrix '(1 2) '(3 4)) (matrix '(1 2) '(3 5)))").should eq("#f")
  end

  it "recognizes matrix? only for matrix values" do
    w("(list (matrix? (matrix '(1))) (matrix? 5))").should eq("(#t #f)")
  end
end
