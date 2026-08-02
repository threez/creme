require "../../spec_helper"

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "R7RS §6.12 Environments and evaluation" do
  it "environment returns a specifier for an environment built by importing the given import sets" do
    w("(import (scheme eval)) (eval '(* 7 3) (environment '(scheme base)))").should eq("21")
  end

  it "environment's import sets support the only/except/prefix/rename combinators" do
    w("(import (scheme eval)) (eval '(+ 10) (environment '(only (scheme base) +)))").should eq("10")
  end

  it "scheme-report-environment returns a specifier for an environment with the R5RS-report bindings" do
    w("(import (scheme eval)(scheme r5rs)) (eval '(* 2 3) (scheme-report-environment 5))").should eq("6")
  end

  it "null-environment returns a specifier for an environment with only syntax, no procedures" do
    w("(import (scheme eval)(scheme r5rs)) (eval '(lambda (f x) (f x x)) (null-environment 5)) 'ok").should eq("ok")
    expect_raises(Creme::SchemeRuntimeError, /unbound variable: \+/) do
      run("(import (scheme eval)(scheme r5rs)) (eval '+ (null-environment 5))")
    end
  end

  it "interaction-environment returns a specifier for the environment a REPL would evaluate typed-in expressions against" do
    w("(import (scheme eval)(scheme repl)) (define x 42) (eval 'x (interaction-environment))").should eq("42")
  end

  it "eval (single-argument form, always evaluating against the global environment) works" do
    w("(import (scheme eval)) (eval '(* 7 3))").should eq("21")
  end

  it "eval's two-argument form evaluates expr-or-def in the specified environment" do
    w(<<-SCM).should eq("20")
      (import (scheme eval))
      (let ((f (eval '(lambda (f x) (f x x)) (environment '(scheme base)))))
        (f + 10))
    SCM
  end
end
