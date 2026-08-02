require "../../spec_helper"

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "(scheme char)" do
  it "(scheme char)'s own library name is not auto-imported (the library table doesn't special-case it the way (scheme base)/(scheme write) are)" do
    expect_raises(Scheme::SchemeRuntimeError, /unbound variable: string-upcase/) do
      run("(string-upcase \"hi\")")
    end
  end

  it "provides char-foldcase, digit-value, string-foldcase, string-ci*, string-upcase/downcase" do
    w("(import (scheme char)) (char-foldcase #\\A)").should eq(%(#\\a))
    w("(import (scheme char)) (digit-value #\\7)").should eq("7")
    w("(import (scheme char)) (digit-value #\\a)").should eq("#f")
    w(%[(import (scheme char)) (string-ci=? "ABC" "abc")]).should eq("#t")
    w(%[(import (scheme char)) (string-foldcase "HeLLo")]).should eq(%("hello"))
    w(%[(import (scheme char)) (string-upcase "hi")]).should eq(%("HI"))
  end
end

describe "(scheme inexact)" do
  it "provides trig/log functions not otherwise in base" do
    w("(import (scheme inexact)) (sin 0)").should eq("0.0")
    w("(import (scheme inexact)) (cos 0)").should eq("1.0")
  end

  it "re-exports sqrt/finite?/infinite?/nan? which are already core" do
    w("(import (scheme inexact)) (sqrt 4)").should eq("2")
    w("(import (scheme inexact)) (nan? (asin 2.0))").should eq("#t")
  end
end

describe "(scheme cxr)" do
  it "provides the depth-3/4 compositions beyond base's caar/cadr/caddr/cadddr" do
    w("(import (scheme cxr)) (caaar '(((1 2) 3) 4))").should eq("1")
    w("(import (scheme cxr)) (cddddr '(1 2 3 4 5))").should eq("(5)")
    w("(import (scheme cxr)) (cadar '((1 2) 3))").should eq("2")
  end

  it "raises a clear error on an improper structure" do
    expect_raises(Scheme::SchemeRuntimeError, /caaar: expected pair/) do
      run("(import (scheme cxr)) (caaar '(1 2 3))")
    end
  end
end

describe "(scheme lazy)" do
  it "provides delay/force/make-promise/promise? (already core, still importable)" do
    w("(import (scheme lazy)) (force (delay (+ 1 2)))").should eq("3")
    w("(import (scheme lazy)) (promise? (delay 1))").should eq("#t")
  end

  it "delay-force resolves a deep chain without growing the stack" do
    w(<<-SCM).should eq("done")
      (import (scheme lazy) (scheme base))
      (define (stream-of n)
        (delay-force
          (if (= n 0) (delay 'done) (stream-of (- n 1)))))
      (force (stream-of 100000))
    SCM
  end
end

describe "(scheme read)" do
  it "provides read" do
    w(%[(import (scheme read) (scheme base)) (read (open-input-string "42"))]).should eq("42")
  end
end

describe "(scheme eval)" do
  it "provides eval" do
    w("(import (scheme eval)) (eval '(+ 1 2))").should eq("3")
  end
end

describe "(scheme process-context)" do
  it "provides command-line, exit, emergency-exit, get-environment-variable(s)" do
    w("(import (scheme process-context) (scheme base)) (list? (command-line))").should eq("#t")
  end

  it "emergency-exit raises SchemeExit, same as exit" do
    interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
    expect_raises(Scheme::SchemeExit) do
      Scheme.run_source(interp, "(import (scheme process-context)) (emergency-exit 3)")
    end
  end
end

describe "(scheme case-lambda)" do
  it "provides case-lambda" do
    w("(import (scheme case-lambda) (scheme base)) (define f (case-lambda ((x) x) ((x y) (+ x y)))) (f 1 2)").should eq("3")
  end
end

describe "(scheme time)" do
  it "provides current-second, current-jiffy, jiffies-per-second per R7RS's contract" do
    w("(import (scheme time) (scheme base)) (> (jiffies-per-second) 0)").should eq("#t")
    w("(import (scheme time) (scheme base)) (>= (current-jiffy) 0)").should eq("#t")
    w("(import (scheme time) (scheme base)) (> (current-second) 0)").should eq("#t")
  end

  it "current-jiffy increases monotonically" do
    interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
    Scheme.run_source(interp, "(import (scheme time) (scheme base))")
    a = Scheme.run_source(interp, "(current-jiffy)").as(Scheme::SchemeInt).value
    b = Scheme.run_source(interp, "(current-jiffy)").as(Scheme::SchemeInt).value
    (b >= a).should be_true
  end
end
