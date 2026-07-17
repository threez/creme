require "../../../spec_helper"

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "(scheme base)" do
  it "is auto-imported: base forms work with zero import lines" do
    w("(+ 1 2)").should eq("3")
    w("(car '(1 2 3))").should eq("1")
  end

  it "every (scheme base) export is bound in @global and callable/referenceable" do
    interp = Scheme::Interpreter.new
    interp.library_export_names(["scheme", "base"]).each do |name|
      interp.global.get?(name).should_not be_nil, "expected #{name} to be bound in @global"
    end
  end

  it "explicitly importing (scheme base) is a harmless no-op" do
    w("(import (scheme base)) (+ 1 2)").should eq("3")
  end

  it "importing (only (scheme base) ...) still resolves against the real @global bindings" do
    w("(import (only (scheme base) +)) (+ 1 2)").should eq("3")
  end

  it "a user-defined library can (import (scheme base)) to use core forms in its body" do
    w(<<-SCM).should eq("6")
      (define-library (test uses-base)
        (export triple)
        (import (scheme base))
        (begin (define (triple x) (* x 3))))
      (import (test uses-base))
      (triple 2)
    SCM
  end
end

describe "(scheme write)" do
  it "display/write are auto-imported: work with zero import lines" do
    interp = Scheme::Interpreter.new
    interp.stdout = out = IO::Memory.new
    Scheme.run_source(interp, %[(display "hi") (write "hi")])
    out.to_s.should eq(%(hi"hi"))
  end

  it "every (scheme write) export is bound in @global" do
    interp = Scheme::Interpreter.new
    interp.library_export_names(["scheme", "write"]).each do |name|
      interp.global.get?(name).should_not be_nil, "expected #{name} to be bound in @global"
    end
  end

  it "explicitly importing (scheme write) is a harmless no-op" do
    interp = Scheme::Interpreter.new
    interp.stdout = out = IO::Memory.new
    Scheme.run_source(interp, %[(import (scheme write)) (display "ok")])
    out.to_s.should eq("ok")
  end
end
