require "../../spec_helper"

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "Appendix B Standard Feature Identifiers" do
  it "features returns the list of feature identifiers this implementation provides" do
    w("(features)").should eq("(r7rs creme creme.cr)")
  end

  it "the r7rs feature identifier is provided, since this implementation satisfies R7RS's own report" do
    w("(cond-expand (r7rs 'yes) (else 'no))").should eq("yes")
  end

  it "cond-expand's else clause is selected for a feature identifier this implementation does not claim" do
    w("(cond-expand (exact-closed 'yes) (else 'no))").should eq("no")
    w("(cond-expand (posix 'yes) (else 'no))").should eq("no")
    w("(cond-expand (full-unicode 'yes) (else 'no))").should eq("no")
  end

  it "cond-expand's (library (name ...)) requirement form checks whether a library is importable" do
    w("(cond-expand ((library (scheme base)) 'yes) (else 'no))").should eq("yes")
    w("(cond-expand ((library (scheme fictional-not-real)) 'yes) (else 'no))").should eq("no")
  end

  it "cond-expand's and/or/not feature-requirement combinators compose correctly against features/libraries" do
    w("(cond-expand ((and r7rs (library (scheme base))) 'yes) (else 'no))").should eq("yes")
    w("(cond-expand ((or exact-closed r7rs) 'yes) (else 'no))").should eq("yes")
    w("(cond-expand ((not exact-closed) 'yes) (else 'no))").should eq("yes")
  end
end
