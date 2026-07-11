require "../../spec_helper"

private def run(src : String) : LISP::LispValue
  interp = LISP::Interpreter.new
  LISP.run_source(interp, "(require 'process) #{src}")
end

describe "process module" do
  it "runs a command and captures stdout/stderr/status/success" do
    result = LISP.list_to_a(run(%((process:run "echo" (list "hi")))))
    result[0].as(LISP::LispStr).value.should eq("hi\n")
    result[1].as(LISP::LispStr).value.should eq("")
    result[2].as(LISP::LispInt).value.should eq(0)
    result[3].as(LISP::LispBool).value.should be_true
  end

  it "reports a non-zero exit status as unsuccessful" do
    result = LISP.list_to_a(run(%((process:run "sh" (list "-c" "exit 1")))))
    result[2].as(LISP::LispInt).value.should eq(1)
    result[3].as(LISP::LispBool).value.should be_false
  end

  it "raises when the command doesn't exist" do
    expect_raises(LISP::LispRuntimeError, /process:run:/) do
      run(%((process:run "this-command-does-not-exist-anywhere" (list))))
    end
  end
end
