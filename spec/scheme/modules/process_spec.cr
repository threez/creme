require "../../spec_helper"

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, "(import (creme process)) #{src}")
end

describe "process module" do
  it "runs a command and captures stdout/stderr/status/success" do
    result = Scheme.list_to_a(run(%((process-run "echo" (list "hi")))))
    result[0].as(Scheme::SchemeStr).value.should eq("hi\n")
    result[1].as(Scheme::SchemeStr).value.should eq("")
    result[2].as(Scheme::SchemeInt).value.should eq(0)
    result[3].as(Scheme::SchemeBool).value?.should be_true
  end

  it "reports a non-zero exit status as unsuccessful" do
    result = Scheme.list_to_a(run(%((process-run "sh" (list "-c" "exit 1")))))
    result[2].as(Scheme::SchemeInt).value.should eq(1)
    result[3].as(Scheme::SchemeBool).value?.should be_false
  end

  it "raises when the command doesn't exist" do
    expect_raises(Scheme::SchemeRuntimeError, /process-run:/) do
      run(%((process-run "this-command-does-not-exist-anywhere" (list))))
    end
  end
end
