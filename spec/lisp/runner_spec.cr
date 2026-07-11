require "../spec_helper"

describe "LISP.run_source" do
  it "evaluates all forms and returns the last result" do
    interp = LISP::Interpreter.new
    result = LISP.run_source(interp, "(define x 1) (+ x 1)")
    result.as(LISP::LispInt).value.should eq(2_i64)
  end

  it "returns nil for empty source" do
    interp = LISP::Interpreter.new
    LISP.run_source(interp, "").should be(LISP::NIL)
  end

  it "propagates a parse error" do
    interp = LISP::Interpreter.new
    expect_raises(LISP::LispParseError) do
      LISP.run_source(interp, ")")
    end
  end

  it "propagates a runtime error" do
    interp = LISP::Interpreter.new
    expect_raises(LISP::LispRuntimeError, /unbound variable/) do
      LISP.run_source(interp, "undefined-var")
    end
  end
end

describe "LISP.run_file" do
  it "reads and evaluates an existing file" do
    interp = LISP::Interpreter.new
    file = File.tempfile("lisp_runner_spec", ".lisp") do |io|
      io.print("(+ 1 2)")
    end
    begin
      result = LISP.run_file(interp, file.path)
      result.as(LISP::LispInt).value.should eq(3_i64)
    ensure
      File.delete(file.path)
    end
  end

  it "raises LispRuntimeError for a missing file" do
    interp = LISP::Interpreter.new
    expect_raises(LISP::LispRuntimeError, /file not found/) do
      LISP.run_file(interp, "/nonexistent/path/does-not-exist.lisp")
    end
  end
end
