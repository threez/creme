require "../../spec_helper"

private def w(src : String) : String
  interp = LISP::Interpreter.new
  LISP.run_source(interp, "(require 'env) #{src}").write_string
end

describe "env module" do
  it "sets, gets, checks, and deletes a variable" do
    key = "LISP_CR_ENV_SPEC_VAR"
    begin
      w(%((env:set! "#{key}" "hello"))).should eq("()")
      w(%((env:get "#{key}"))).should eq(%("hello"))
      w(%((env:has? "#{key}"))).should eq("#t")
      w(%((env:delete! "#{key}"))).should eq("()")
      w(%((env:has? "#{key}"))).should eq("#f")
    ensure
      ENV.delete(key)
    end
  end

  it "returns #f for a variable that isn't set" do
    w(%((env:get "LISP_CR_ENV_SPEC_MISSING_VAR"))).should eq("#f")
  end

  it "exposes all variables as an alist" do
    key = "LISP_CR_ENV_SPEC_ALL_VAR"
    ENV[key] = "present"
    begin
      interp = LISP::Interpreter.new
      result = LISP.run_source(interp, %[(require 'env) (assoc "#{key}" (env:all))])
      result.should be_a(LISP::Cons)
      result.as(LISP::Cons).cdr.as(LISP::LispStr).value.should eq("present")
    ensure
      ENV.delete(key)
    end
  end
end
