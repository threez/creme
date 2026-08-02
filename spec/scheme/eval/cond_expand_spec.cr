require "../../spec_helper"

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "cond-expand" do
  it "matches a satisfied feature identifier" do
    w("(cond-expand (r7rs 'yes) (else 'no))").should eq("yes")
  end

  it "falls through to else when no feature matches" do
    w("(cond-expand (no-such-feature 'yes) (else 'no))").should eq("no")
  end

  it "returns NIL and raises nothing when no clause matches and there is no else" do
    w("(cond-expand (no-such-feature 'yes))").should eq("()")
  end

  it "supports (library (name...)) clauses" do
    w("(cond-expand ((library (scheme base)) 'yes) (else 'no))").should eq("yes")
    w("(cond-expand ((library (no such lib)) 'yes) (else 'no))").should eq("no")
  end

  it "supports and/or/not combinations" do
    w("(cond-expand ((and r7rs (not no-such-feature)) 'yes) (else 'no))").should eq("yes")
    w("(cond-expand ((or no-such-feature r7rs) 'yes) (else 'no))").should eq("yes")
    w("(cond-expand ((and r7rs no-such-feature) 'yes) (else 'no))").should eq("no")
  end

  it "evaluates a multi-form body, returning the last form's value" do
    w("(cond-expand (r7rs 1 2 3) (else 'no))").should eq("3")
  end
end

describe "features" do
  it "returns a list including r7rs" do
    w("(features)").should eq("(r7rs creme creme.cr)")
  end
end
