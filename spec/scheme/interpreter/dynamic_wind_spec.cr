require "../../spec_helper"

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "dynamic-wind" do
  it "runs before, thunk, after in order on normal return" do
    w(<<-SCM).should eq("(before during after)")
      (define log '())
      (dynamic-wind
        (lambda () (set! log (cons 'before log)))
        (lambda () (set! log (cons 'during log)))
        (lambda () (set! log (cons 'after log))))
      (reverse log)
    SCM
  end

  it "returns the thunk's value" do
    w("(dynamic-wind (lambda () 'x) (lambda () 42) (lambda () 'y))").should eq("42")
  end

  it "runs after even when the thunk raises, before the error propagates out" do
    w(<<-SCM).should eq("(before after)")
      (define log '())
      (guard (e (#t 'caught))
        (dynamic-wind
          (lambda () (set! log (cons 'before log)))
          (lambda () (error "boom"))
          (lambda () (set! log (cons 'after log)))))
      (reverse log)
    SCM
  end

  it "the error still reaches guard after after runs" do
    w(<<-SCM).should eq("caught")
      (guard (e (#t 'caught))
        (dynamic-wind (lambda () 'b) (lambda () (error "boom")) (lambda () 'a)))
    SCM
  end

  it "runs after when the thunk escapes via a call/cc continuation invoked from inside" do
    w(<<-SCM).should eq("(before after)")
      (define log '())
      (call/cc (lambda (k)
        (dynamic-wind
          (lambda () (set! log (cons 'before log)))
          (lambda () (k 'escaped) (set! log (cons 'never log)))
          (lambda () (set! log (cons 'after log))))))
      (reverse log)
    SCM
  end

  it "runs after for every dynamic-wind frame a continuation escapes past, innermost first" do
    w(<<-SCM).should eq("(outer-before inner-before inner-after outer-after)")
      (define log '())
      (call/cc (lambda (k)
        (dynamic-wind
          (lambda () (set! log (cons 'outer-before log)))
          (lambda ()
            (dynamic-wind
              (lambda () (set! log (cons 'inner-before log)))
              (lambda () (k 'escaped-both))
              (lambda () (set! log (cons 'inner-after log)))))
          (lambda () (set! log (cons 'outer-after log))))))
      (reverse log)
    SCM
  end

  it "nests in correct LIFO order for normal (non-escaping) execution" do
    w(<<-SCM).should eq("(a-before b-before b-during b-after a-after)")
      (define log '())
      (dynamic-wind
        (lambda () (set! log (cons 'a-before log)))
        (lambda ()
          (dynamic-wind
            (lambda () (set! log (cons 'b-before log)))
            (lambda () (set! log (cons 'b-during log)))
            (lambda () (set! log (cons 'b-after log)))))
        (lambda () (set! log (cons 'a-after log))))
      (reverse log)
    SCM
  end

  it "interacts correctly with raise/with-exception-handler: after runs, handler stack stays consistent" do
    w(<<-SCM).should eq("(before after)")
      (define log '())
      (guard (e (#t 'caught))
        (with-exception-handler
          (lambda (e) (raise e))
          (lambda ()
            (dynamic-wind
              (lambda () (set! log (cons 'before log)))
              (lambda () (raise-continuable 'oops))
              (lambda () (set! log (cons 'after log)))))))
      (reverse log)
    SCM
  end

  it "known limitation: invoking a continuation captured inside, after dynamic-wind already returned, raises a clean error rather than re-entering" do
    w(<<-SCM).should eq("clean-error")
      (define saved-k #f)
      (dynamic-wind
        (lambda () 'before)
        (lambda () (call/cc (lambda (k) (set! saved-k k))))
        (lambda () 'after))
      (guard (e (#t 'clean-error)) (saved-k 'reenter))
    SCM
  end

  it "raises for the wrong number of arguments" do
    expect_raises(Scheme::SchemeRuntimeError) { run("(dynamic-wind (lambda () 1) (lambda () 2))") }
  end
end
