require "../../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (creme env)) #{src}").write_string
end

describe "env module" do
  it "sets, gets, checks, and deletes a variable" do
    key = "SCHEME_CR_ENV_SPEC_VAR"
    begin
      w(%((set-environment-variable! "#{key}" "hello"))).should eq("()")
      w(%((get-environment-variable "#{key}"))).should eq(%("hello"))
      w(%((environment-variable-set? "#{key}"))).should eq("#t")
      w(%((delete-environment-variable! "#{key}"))).should eq("()")
      w(%((environment-variable-set? "#{key}"))).should eq("#f")
    ensure
      ENV.delete(key)
    end
  end

  it "returns #f for a variable that isn't set" do
    w(%((get-environment-variable "SCHEME_CR_ENV_SPEC_MISSING_VAR"))).should eq("#f")
  end

  it "exposes all variables as an alist" do
    key = "SCHEME_CR_ENV_SPEC_ALL_VAR"
    ENV[key] = "present"
    begin
      interp = Creme::Interpreter.new(library_search_path: ["./modules"])
      result = Creme.run_source(interp, %[(import (creme env)) (assoc "#{key}" (get-environment-variables))])
      result.should be_a(Creme::Cons)
      result.as(Creme::Cons).cdr.as(Creme::SchemeStr).value.should eq("present")
    ensure
      ENV.delete(key)
    end
  end
end
