require "../../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme random)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme random)) #{src}")
end

describe "random module" do
  it "produces deterministic output once seeded" do
    w("(random-seed! 42) (random-integer 100)").should eq(w("(random-seed! 42) (random-integer 100)"))
  end

  it "random-integer stays within [0, n)" do
    interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
    result = Scheme.run_source(interp, "(import (creme random)) (random-seed! 7) (list (random-integer 1) (random-integer 2))")
    values = Scheme.list_to_a(result)
    values[0].as(Scheme::SchemeInt).value.should eq(0)
    [0_i64, 1_i64].should contain(values[1].as(Scheme::SchemeInt).value)
  end

  it "raises when n is not positive" do
    expect_raises(Scheme::SchemeRuntimeError, /random-integer: n must be positive/) do
      run("(random-integer 0)")
    end
  end

  it "choice picks an element from the list" do
    interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
    result = Scheme.run_source(interp, "(import (creme random)) (random-seed! 1) (random-choice (list 1 2 3))")
    [1_i64, 2_i64, 3_i64].should contain(result.as(Scheme::SchemeInt).value)
  end

  it "raises on choice from an empty list" do
    expect_raises(Scheme::SchemeRuntimeError, /random-choice: expects a non-empty list/) do
      run("(random-choice (list))")
    end
  end

  it "shuffle returns a permutation of the same elements" do
    interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
    result = Scheme.run_source(interp, "(import (creme random)) (random-seed! 3) (random-shuffle (list 1 2 3 4 5))")
    Scheme.list_to_a(result).map(&.as(Scheme::SchemeInt).value).sort!.should eq([1_i64, 2_i64, 3_i64, 4_i64, 5_i64])
  end
end
