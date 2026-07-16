require "../spec_helper"

describe "Scheme.run_source" do
  it "evaluates all forms and returns the last result" do
    interp = Scheme::Interpreter.new
    result = Scheme.run_source(interp, "(define x 1) (+ x 1)")
    result.as(Scheme::SchemeInt).value.should eq(2_i64)
  end

  it "returns nil for empty source" do
    interp = Scheme::Interpreter.new
    Scheme.run_source(interp, "").should eq(Scheme::NIL)
  end

  it "propagates a parse error" do
    interp = Scheme::Interpreter.new
    expect_raises(Scheme::SchemeParseError) do
      Scheme.run_source(interp, ")")
    end
  end

  it "propagates a runtime error" do
    interp = Scheme::Interpreter.new
    expect_raises(Scheme::SchemeRuntimeError, /unbound variable/) do
      Scheme.run_source(interp, "undefined-var")
    end
  end
end

describe "Scheme.run_file" do
  it "reads and evaluates an existing file" do
    interp = Scheme::Interpreter.new
    file = File.tempfile("lisp_runner_spec", ".scm") do |io|
      io.print("(+ 1 2)")
    end
    begin
      result = Scheme.run_file(interp, file.path)
      result.as(Scheme::SchemeInt).value.should eq(3_i64)
    ensure
      File.delete(file.path)
    end
  end

  it "raises SchemeRuntimeError for a missing file" do
    interp = Scheme::Interpreter.new
    expect_raises(Scheme::SchemeRuntimeError, /file not found/) do
      Scheme.run_file(interp, "/nonexistent/path/does-not-exist.scm")
    end
  end

  it "makes bindings visible inside the file" do
    interp = Scheme::Interpreter.new
    file = File.tempfile("lisp_runner_spec_bindings", ".scm") do |io|
      io.print("(+ x 1)")
    end
    begin
      bindings = {"x" => Scheme::SchemeInt.new(9_i64)} of String => Scheme::SchemeValue
      result = Scheme.run_file(interp, file.path, bindings: bindings)
      result.as(Scheme::SchemeInt).value.should eq(10_i64)
    ensure
      File.delete(file.path)
    end
  end
end

describe "Scheme.run_source with bindings/parent" do
  it "makes bindings visible inside the script" do
    interp = Scheme::Interpreter.new
    bindings = {"x" => Scheme::SchemeInt.new(41_i64)} of String => Scheme::SchemeValue
    result = Scheme.run_source(interp, "(+ x 1)", bindings: bindings)
    result.as(Scheme::SchemeInt).value.should eq(42_i64)
  end

  it "isolates a define inside a bindings call from interp.global" do
    interp = Scheme::Interpreter.new
    empty = {} of String => Scheme::SchemeValue
    Scheme.run_source(interp, "(define y 1)", bindings: empty)
    expect_raises(Scheme::SchemeRuntimeError, /unbound variable: y/) do
      interp.global.get("y")
    end
  end

  it "isolates a define inside one bindings call from a later bindings call" do
    interp = Scheme::Interpreter.new
    empty = {} of String => Scheme::SchemeValue
    Scheme.run_source(interp, "(define y 1)", bindings: empty)
    expect_raises(Scheme::SchemeRuntimeError, /unbound variable: y/) do
      Scheme.run_source(interp, "y", bindings: empty)
    end
  end

  it "omitting bindings/parent preserves the existing cross-call global-sharing behavior" do
    interp = Scheme::Interpreter.new
    Scheme.run_source(interp, "(define z 7)")
    Scheme.run_source(interp, "z").as(Scheme::SchemeInt).value.should eq(7_i64)
  end

  it "lets a callback registered on a reusable parent env be shared across isolated calls" do
    interp = Scheme::Interpreter.new
    session = Scheme::Env.new(interp.global)
    session.define_fn("double", 1, 1) { |args| Scheme::SchemeInt.new(args[0].as(Scheme::SchemeInt).value * 2) }

    b1 = {"x" => Scheme::SchemeInt.new(3_i64)} of String => Scheme::SchemeValue
    b2 = {"x" => Scheme::SchemeInt.new(10_i64)} of String => Scheme::SchemeValue
    r1 = Scheme.run_source(interp, "(double x)", bindings: b1, parent: session)
    r2 = Scheme.run_source(interp, "(double x)", bindings: b2, parent: session)
    r1.as(Scheme::SchemeInt).value.should eq(6_i64)
    r2.as(Scheme::SchemeInt).value.should eq(20_i64)
  end

  it "parent alone (no bindings) evals directly against the given env" do
    interp = Scheme::Interpreter.new
    session = Scheme::Env.new(interp.global)
    session.define("x", Scheme::SchemeInt.new(5_i64))
    Scheme.run_source(interp, "x", parent: session).as(Scheme::SchemeInt).value.should eq(5_i64)
  end
end
