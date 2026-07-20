require "../../../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (scheme base) (creme syntax mex)) #{src}").write_string
end

describe "(creme syntax mex)" do
  it "desugars an adjacent call: f(x y) => (f x y)" do
    w(%[(read-program "f(x y)" "t" (quote ()))]).should eq(%[((f x y))])
  end

  it "does not desugar when a space breaks adjacency" do
    w(%[(read-program "f (x y)" "t" (quote ()))]).should eq(%[(f (x y))])
  end

  it "nests correctly: g(f(x)) => (g (f x))" do
    w(%[(read-program "g(f(x))" "t" (quote ()))]).should eq(%[((g (f x)))])
  end

  it "composes with quoting: 'f(x y) => (quote (f x y))" do
    w(%[(read-program "'f(x y)" "t" (quote ()))]).should eq(%[((quote (f x y)))])
  end

  it "leaves plain data lists untouched" do
    w(%[(read-program "(list 1 2 3)" "t" (quote ()))]).should eq(%[((list 1 2 3))])
  end
end
