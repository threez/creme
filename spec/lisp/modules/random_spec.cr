require "../../spec_helper"

private def w(src : String) : String
  interp = LISP::Interpreter.new
  LISP.run_source(interp, "(require 'random) #{src}").write_string
end

private def run(src : String) : LISP::LispValue
  interp = LISP::Interpreter.new
  LISP.run_source(interp, "(require 'random) #{src}")
end

describe "random module" do
  it "produces deterministic output once seeded" do
    w("(random:seed 42) (random:int 1 100)").should eq(w("(random:seed 42) (random:int 1 100)"))
  end

  it "int stays within the requested inclusive range" do
    interp = LISP::Interpreter.new
    result = LISP.run_source(interp, "(require 'random) (random:seed 7) (list (random:int 5 5) (random:int 1 2))")
    values = LISP.list_to_a(result)
    values[0].as(LISP::LispInt).value.should eq(5)
    [1_i64, 2_i64].should contain(values[1].as(LISP::LispInt).value)
  end

  it "raises when min > max" do
    expect_raises(LISP::LispRuntimeError, /random:int: min must be <= max/) do
      run("(random:int 5 1)")
    end
  end

  it "choice picks an element from the list" do
    interp = LISP::Interpreter.new
    result = LISP.run_source(interp, "(require 'random) (random:seed 1) (random:choice (list 1 2 3))")
    [1_i64, 2_i64, 3_i64].should contain(result.as(LISP::LispInt).value)
  end

  it "raises on choice from an empty list" do
    expect_raises(LISP::LispRuntimeError, /random:choice: expects a non-empty list/) do
      run("(random:choice (list))")
    end
  end

  it "shuffle returns a permutation of the same elements" do
    interp = LISP::Interpreter.new
    result = LISP.run_source(interp, "(require 'random) (random:seed 3) (random:shuffle (list 1 2 3 4 5))")
    LISP.list_to_a(result).map(&.as(LISP::LispInt).value).sort!.should eq([1_i64, 2_i64, 3_i64, 4_i64, 5_i64])
  end
end
