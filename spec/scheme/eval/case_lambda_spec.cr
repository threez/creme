require "../../spec_helper"

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "case-lambda" do
  it "dispatches to the clause matching the call's argument count" do
    src = <<-SCM
      (define f (case-lambda
        ((x) (list 'one x))
        ((x y) (list 'two x y))
        ((x y . rest) (list 'many x y rest))))
    SCM
    w("#{src} (f 1)").should eq("(one 1)")
    w("#{src} (f 1 2)").should eq("(two 1 2)")
    w("#{src} (f 1 2 3 4)").should eq("(many 1 2 (3 4))")
  end

  it "raises when no clause matches the call's argument count" do
    expect_raises(Scheme::SchemeRuntimeError, /no matching clause/) do
      run("(define f (case-lambda ((x) x))) (f)")
    end
  end

  it "supports tail recursion through a matched clause" do
    w(<<-SCM).should eq("500000500000")
      (define count (case-lambda
        ((n) (count n 0))
        ((n acc) (if (= n 0) acc (count (- n 1) (+ acc n))))))
      (count 1000000)
    SCM
  end

  it "is a real procedure value usable with apply/map" do
    w(<<-SCM).should eq("(1 4)")
      (define f (case-lambda ((x) x) ((x y) (* x y))))
      (list (apply f '(1)) (apply f '(2 2)))
    SCM
  end
end
