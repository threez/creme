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

  it "makes bindings visible inside the file" do
    interp = LISP::Interpreter.new
    file = File.tempfile("lisp_runner_spec_bindings", ".lisp") do |io|
      io.print("(+ x 1)")
    end
    begin
      bindings = {"x" => LISP::LispInt.new(9_i64)} of String => LISP::LispValue
      result = LISP.run_file(interp, file.path, bindings: bindings)
      result.as(LISP::LispInt).value.should eq(10_i64)
    ensure
      File.delete(file.path)
    end
  end
end

describe "LISP.run_source with bindings/parent" do
  it "makes bindings visible inside the script" do
    interp = LISP::Interpreter.new
    bindings = {"x" => LISP::LispInt.new(41_i64)} of String => LISP::LispValue
    result = LISP.run_source(interp, "(+ x 1)", bindings: bindings)
    result.as(LISP::LispInt).value.should eq(42_i64)
  end

  it "isolates a define inside a bindings call from interp.global" do
    interp = LISP::Interpreter.new
    empty = {} of String => LISP::LispValue
    LISP.run_source(interp, "(define y 1)", bindings: empty)
    expect_raises(LISP::LispRuntimeError, /unbound variable: y/) do
      interp.global.get("y")
    end
  end

  it "isolates a define inside one bindings call from a later bindings call" do
    interp = LISP::Interpreter.new
    empty = {} of String => LISP::LispValue
    LISP.run_source(interp, "(define y 1)", bindings: empty)
    expect_raises(LISP::LispRuntimeError, /unbound variable: y/) do
      LISP.run_source(interp, "y", bindings: empty)
    end
  end

  it "omitting bindings/parent preserves the existing cross-call global-sharing behavior" do
    interp = LISP::Interpreter.new
    LISP.run_source(interp, "(define z 7)")
    LISP.run_source(interp, "z").as(LISP::LispInt).value.should eq(7_i64)
  end

  it "lets a callback registered on a reusable parent env be shared across isolated calls" do
    interp = LISP::Interpreter.new
    session = LISP::Env.new(interp.global)
    session.define_fn("double", 1, 1) { |args| LISP::LispInt.new(args[0].as(LISP::LispInt).value * 2) }

    b1 = {"x" => LISP::LispInt.new(3_i64)} of String => LISP::LispValue
    b2 = {"x" => LISP::LispInt.new(10_i64)} of String => LISP::LispValue
    r1 = LISP.run_source(interp, "(double x)", bindings: b1, parent: session)
    r2 = LISP.run_source(interp, "(double x)", bindings: b2, parent: session)
    r1.as(LISP::LispInt).value.should eq(6_i64)
    r2.as(LISP::LispInt).value.should eq(20_i64)
  end

  it "parent alone (no bindings) evals directly against the given env" do
    interp = LISP::Interpreter.new
    session = LISP::Env.new(interp.global)
    session.define("x", LISP::LispInt.new(5_i64))
    LISP.run_source(interp, "x", parent: session).as(LISP::LispInt).value.should eq(5_i64)
  end
end
