require "../../spec_helper"

private def w(src : String) : String
  interp = LISP::Interpreter.new
  LISP.run_source(interp, "(require 'file) #{src}").write_string
end

private def run(src : String) : LISP::LispValue
  interp = LISP::Interpreter.new
  LISP.run_source(interp, "(require 'file) #{src}")
end

describe "file module" do
  it "writes, reads, checks existence, sizes, and deletes a file" do
    path = File.tempname("lisp_file_spec")
    begin
      w(%((file:write "#{path}" "hello"))).should eq("()")
      w(%((file:read "#{path}"))).should eq(%("hello"))
      w(%((file:exists? "#{path}"))).should eq("#t")
      w(%((file:size "#{path}"))).should eq("5")
      w(%((file:append "#{path}" " world"))).should eq("()")
      w(%((file:read "#{path}"))).should eq(%("hello world"))
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "reads lines" do
    path = File.tempname("lisp_file_spec_lines")
    File.write(path, "a\nb\nc\n")
    begin
      w(%((file:lines "#{path}"))).should eq(%(("a" "b" "c")))
    ensure
      File.delete(path)
    end
  end

  it "reports non-existence" do
    w(%((file:exists? "/no/such/path/lisp-spec"))).should eq("#f")
  end

  it "raises when reading a missing file" do
    expect_raises(LISP::LispRuntimeError, /file:read: file not found/) do
      run(%((file:read "/no/such/path/lisp-spec")))
    end
  end
end
