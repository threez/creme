require "../../spec_helper"

private def run(src : String) : LISP::LispValue
  interp = LISP::Interpreter.new
  LISP.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "require" do
  it "loads a module and makes qualified names callable" do
    w("(require 'math) (math:sin 0)").should eq("0.0")
  end

  it "also accepts a bare (unquoted) symbol" do
    w("(require math) (math:sin 0)").should eq("0.0")
  end

  it "is idempotent" do
    w("(require 'math) (require 'math) (math:sin 0)").should eq("0.0")
  end

  it "raises on an unknown module" do
    expect_raises(LISP::LispRuntimeError, /require: unknown module 'nope'/) do
      run("(require 'nope)")
    end
  end

  it "raises when using a qualified symbol from a package that was never required" do
    expect_raises(LISP::LispRuntimeError, /unbound package: math/) do
      run("(math:sin 0)")
    end
  end

  it "raises when the required symbol doesn't exist in the package" do
    expect_raises(LISP::LispRuntimeError, /unbound variable: nope/) do
      run("(require 'math) (math:nope)")
    end
  end

  it "raises for a non-symbol argument" do
    expect_raises(LISP::LispRuntimeError, /require: argument must be a symbol/) do
      run(%((require "math")))
    end
  end
end
