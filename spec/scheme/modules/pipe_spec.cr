require "../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (creme pipe)) #{src}").write_string
end

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (creme pipe)) #{src}")
end

describe "pipe module" do
  it "returns the value unchanged with no steps" do
    w("(pipe 5)").should eq("5")
  end

  it "threads a value through bare-identifier steps" do
    w("(pipe 5 -)").should eq("-5")
  end

  it "threads a value in as the first argument of list steps" do
    w("(pipe 5 (+ 1) (* 2))").should eq("12")
  end

  it "mixes bare-identifier and list steps" do
    w("(pipe 5 (+ 1) (* 2) -)").should eq("-12")
  end

  it "supports extra arguments after the threaded value" do
    w("(pipe (vector 1 4 9) (vector-ref 1))").should eq("4")
  end

  it "raises when trying to call pipe outside a use of its macro" do
    expect_raises(Creme::SchemeError) { run("(pipe)") }
  end
end
