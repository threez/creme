require "../../spec_helper"
require "file_utils"

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "Appendix A Standard Libraries" do
  it "(scheme base) imports and every (scheme base) export is bound in @global" do
    interp = Scheme::Interpreter.new
    interp.library_export_names(["scheme", "base"]).each do |name|
      interp.global.get?(name).should_not be_nil, "expected #{name} to be bound in @global"
    end
  end

  it "(scheme write) imports and exports display/write" do
    w("(import (scheme write)) (+ 1 1)").should eq("2")
    interp = Scheme::Interpreter.new
    interp.library_export_names(["scheme", "write"]).each do |name|
      interp.global.get?(name).should_not be_nil, "expected #{name} to be bound in @global"
    end
  end

  it "(scheme case-lambda) exports case-lambda, and its result is callable" do
    w("(import (scheme case-lambda)) ((case-lambda ((x) x)) 5)").should eq("5")
  end

  it "procedure? recognizes a case-lambda value as a procedure" do
    w("(import (scheme case-lambda)) (procedure? (case-lambda ((x) x)))").should eq("#t")
  end

  it "(scheme char) exports the Unicode-table-dependent character/string procedures" do
    w("(import (scheme char)) (char-foldcase #\\A)").should eq("#\\a")
  end

  it "(scheme complex) exports procedures typically only useful with non-real numbers" do
    w("(import (scheme complex)) (real-part 3)").should eq("3")
  end

  it "(scheme cxr) exports the depth-3/4 car/cdr compositions" do
    w("(import (scheme cxr)) (caaar '(((1 2) 3) 4))").should eq("1")
  end

  it "(scheme eval) exports eval" do
    w("(import (scheme eval)) (eval '(+ 1 1))").should eq("2")
  end

  it "(scheme file) provides procedures for accessing files" do
    dir = File.tempname("creme-r7rs-appendix-a-spec", "")
    Dir.mkdir_p(dir)
    begin
      path = File.join(dir, "probe.txt")
      w(%[(import (scheme file)) (file-exists? "#{path}")]).should eq("#f")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "(scheme inexact) exports procedures typically only useful with inexact values" do
    w("(import (scheme inexact)) (finite? 3)").should eq("#t")
  end

  it "(scheme lazy) exports promise-related syntax/procedures" do
    w("(import (scheme lazy)) (promise? (delay 1))").should eq("#t")
  end

  it "(scheme load) provides the load procedure" do
    dir = File.tempname("creme-r7rs-appendix-a-spec", "")
    Dir.mkdir_p(dir)
    begin
      File.write(File.join(dir, "answer.scm"), "(define answer 42)")
      interp = Scheme::Interpreter.new
      interp.push_load_dir(dir)
      Scheme.run_source(interp, <<-SCM).write_string.should eq("42")
        (import (scheme load))
        (load "answer.scm")
        answer
      SCM
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "(scheme process-context) exports command-line/exit/environment-variable access" do
    w("(import (scheme process-context)) (list? (command-line))").should eq("#t")
  end

  it "(scheme read) exports read" do
    w("(import (scheme read)) (read (open-input-string \"a\"))").should eq("a")
  end

  it "(scheme repl) exports interaction-environment" do
    w("(import (scheme eval)(scheme repl)) (define x 7) (eval 'x (interaction-environment))").should eq("7")
  end

  it "(scheme time) exports current-second/current-jiffy/jiffies-per-second" do
    w("(import (scheme time)) (number? (current-second))").should eq("#t")
  end

  it "(scheme r5rs) exports the R5RS-report bindings, including null-environment/scheme-report-environment" do
    w("(import (scheme r5rs)) (+ 1 2)").should eq("3")
    w("(import (scheme eval)(scheme r5rs)) (eval '(* 2 3) (scheme-report-environment 5))").should eq("6")
  end

  it "importing an unknown library name (not just an unimplemented standard one) raises the same clear error" do
    expect_raises(Scheme::SchemeRuntimeError, /import: unknown library \(totally not a real library\)/) do
      run("(import (totally not a real library))")
    end
  end
end
