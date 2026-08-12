require "../spec_helper"

describe "Creme.run_source" do
  it "evaluates all forms and returns the last result" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    result = Creme.run_source(interp, "(define x 1) (+ x 1)")
    result.as(Creme::SchemeInt).value.should eq(2_i64)
  end

  it "returns nil for empty source" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    Creme.run_source(interp, "").should eq(Creme::NIL)
  end

  it "propagates a parse error" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    expect_raises(Creme::SchemeParseError) do
      Creme.run_source(interp, ")")
    end
  end

  it "propagates a runtime error" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    expect_raises(Creme::SchemeRuntimeError, /unbound variable/) do
      Creme.run_source(interp, "undefined-var")
    end
  end

  it "returns the assigned value, not the symbol, when the script ends in a variable define" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    result = Creme.run_source(interp, "(define x 42)")
    result.as(Creme::SchemeInt).value.should eq(42_i64)
  end

  it "returns the assigned value, not the symbol, when a trailing define follows other forms" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    result = Creme.run_source(interp, "(+ 1 2) (define x 42)")
    result.as(Creme::SchemeInt).value.should eq(42_i64)
  end

  it "returns the closure, not the symbol, when the script ends in a function define" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    result = Creme.run_source(interp, "(define (f n) n)")
    result.should be_a(Creme::BytecodeClosure)
  end

  it "still returns an ordinary result when the script does not end in a define" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    result = Creme.run_source(interp, "(define x 1) x")
    result.as(Creme::SchemeInt).value.should eq(1_i64)
  end
end

describe "Creme.run_file" do
  it "reads and evaluates an existing file" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    file = File.tempfile("lisp_runner_spec", ".scm") do |io|
      io.print("(+ 1 2)")
    end
    begin
      result = Creme.run_file(interp, file.path)
      result.as(Creme::SchemeInt).value.should eq(3_i64)
    ensure
      File.delete(file.path)
    end
  end

  it "raises SchemeRuntimeError for a missing file" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    expect_raises(Creme::SchemeRuntimeError, /file not found/) do
      Creme.run_file(interp, "/nonexistent/path/does-not-exist.scm")
    end
  end

  it "makes bindings visible inside the file" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    file = File.tempfile("lisp_runner_spec_bindings", ".scm") do |io|
      io.print("(+ x 1)")
    end
    begin
      bindings = {"x" => Creme::SchemeInt.new(9_i64)} of String => Creme::SchemeValue
      result = Creme.run_file(interp, file.path, bindings: bindings)
      result.as(Creme::SchemeInt).value.should eq(10_i64)
    ensure
      File.delete(file.path)
    end
  end
end

describe "Creme.run_source with bindings/parent" do
  it "makes bindings visible inside the script" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    bindings = {"x" => Creme::SchemeInt.new(41_i64)} of String => Creme::SchemeValue
    result = Creme.run_source(interp, "(+ x 1)", bindings: bindings)
    result.as(Creme::SchemeInt).value.should eq(42_i64)
  end

  it "isolates a define inside a bindings call from interp.global" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    empty = {} of String => Creme::SchemeValue
    Creme.run_source(interp, "(define y 1)", bindings: empty)
    expect_raises(Creme::SchemeRuntimeError, /unbound variable: y/) do
      interp.global.get("y")
    end
  end

  it "isolates a define inside one bindings call from a later bindings call" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    empty = {} of String => Creme::SchemeValue
    Creme.run_source(interp, "(define y 1)", bindings: empty)
    expect_raises(Creme::SchemeRuntimeError, /unbound variable: y/) do
      Creme.run_source(interp, "y", bindings: empty)
    end
  end

  it "omitting bindings/parent preserves the existing cross-call global-sharing behavior" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    Creme.run_source(interp, "(define z 7)")
    Creme.run_source(interp, "z").as(Creme::SchemeInt).value.should eq(7_i64)
  end

  it "lets a callback registered on a reusable parent env be shared across isolated calls" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    session = Creme::Env.new(interp.global)
    session.define_fn("double", 1, 1) { |args| Creme::SchemeInt.new(args[0].as(Creme::SchemeInt).value * 2) }

    b1 = {"x" => Creme::SchemeInt.new(3_i64)} of String => Creme::SchemeValue
    b2 = {"x" => Creme::SchemeInt.new(10_i64)} of String => Creme::SchemeValue
    r1 = Creme.run_source(interp, "(double x)", bindings: b1, parent: session)
    r2 = Creme.run_source(interp, "(double x)", bindings: b2, parent: session)
    r1.as(Creme::SchemeInt).value.should eq(6_i64)
    r2.as(Creme::SchemeInt).value.should eq(20_i64)
  end

  it "parent alone (no bindings) evals directly against the given env" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    session = Creme::Env.new(interp.global)
    session.define("x", Creme::SchemeInt.new(5_i64))
    Creme.run_source(interp, "x", parent: session).as(Creme::SchemeInt).value.should eq(5_i64)
  end
end

describe "#lang" do
  it "run_source runs a file whose #lang line names a dialect library with no extra header-args" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    result = Creme.run_source(interp, "#lang (creme syntax scss)\na { color: red; }\n")
    result.write_string.should eq("()")
  end

  it "run_source passes extra header-line data through as header-args, selecting a dialect's define-mode" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    Creme.run_source(interp, "#lang (creme syntax scss) (export css)\na { color: red; }\n")
    interp.global.get("css").as(Creme::SchemeStr).value.should eq("a {\n  color: red;\n}\n")
  end

  it "load respects a #lang header exactly like run_source, defining into the target env" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    file = File.tempfile("lisp_runner_spec_lang", ".scss") do |io|
      io.print("#lang (creme syntax scss) (export css)\na { color: blue; }\n")
    end
    begin
      Creme.run_source(interp, %(#{"(import (scheme base) (scheme load))"} (load #{file.path.inspect})))
      interp.global.get("css").as(Creme::SchemeStr).value.should eq("a {\n  color: blue;\n}\n")
    ensure
      File.delete(file.path)
    end
  end

  it "a plain file with no #lang line is completely unaffected" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    Creme.run_source(interp, "(+ 1 2)").as(Creme::SchemeInt).value.should eq(3_i64)
  end
end
