require "../../../../spec_helper"

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "raise" do
  it "unwinds to the nearest guard when no handler is installed" do
    w(%[(guard (e (#t (list 'caught e))) (raise 'my-symbol))]).should eq("(caught my-symbol)")
  end

  it "carries an arbitrary raised object, not just an error-object condition" do
    w(%[(guard (e (#t e)) (raise (list 1 2 3)))]).should eq("(1 2 3)")
    w(%[(guard (e (#t e)) (raise "a string"))]).should eq(%("a string"))
    w(%[(guard (e (#t e)) (raise 42))]).should eq("42")
  end

  it "propagates past an inner guard whose clauses don't match, to an outer guard" do
    w(<<-SCM).should eq("outer")
      (guard (e (#t 'outer))
        (guard (e ((symbol? e) 'inner))
          (raise "not a symbol")))
    SCM
  end
end

describe "with-exception-handler + raise (non-continuable)" do
  it "calls the installed handler with the raised object" do
    w(<<-SCM).should eq("(handled boom)")
      (guard (e (#t e))
        (with-exception-handler
          (lambda (e) (raise (list 'handled e)))
          (lambda () (raise 'boom))))
    SCM
  end

  it "is an error if the handler returns normally instead of escaping" do
    w(<<-SCM).should eq("(outer-caught boom)")
      (guard (e (#t (list 'outer-caught e)))
        (with-exception-handler
          (lambda (e) 'ignored-return-value)
          (lambda () (raise 'boom))))
    SCM
  end
end

describe "raise-continuable" do
  it "returns the handler's value in-line at the raise-continuable call site" do
    w(<<-SCM).should eq("101")
      (with-exception-handler
        (lambda (e) 100)
        (lambda () (+ 1 (raise-continuable 'oops))))
    SCM
  end

  it "does not require the handler to escape" do
    w(<<-SCM).should eq("(3 4 5)")
      (with-exception-handler
        (lambda (e) 3)
        (lambda () (list (raise-continuable 'x) 4 5)))
    SCM
  end
end

describe "nested with-exception-handler scoping" do
  it "a handler that itself raises sees the NEXT outer handler, not itself" do
    w(<<-SCM).should eq("(outer (re-raised inner))")
      (with-exception-handler
        (lambda (e) (list 'outer e))
        (lambda ()
          (with-exception-handler
            (lambda (e) (raise-continuable (list 're-raised e)))
            (lambda () (raise-continuable 'inner)))))
    SCM
  end

  it "the handler stack is restored after with-exception-handler returns normally" do
    w(<<-SCM).should eq("(first second)")
      (define log '())
      (with-exception-handler
        (lambda (e) (set! log (cons 'first log)) 'ignored)
        (lambda () (raise-continuable 'a)))
      (with-exception-handler
        (lambda (e) (set! log (cons 'second log)) 'ignored)
        (lambda () (raise-continuable 'b)))
      (reverse log)
    SCM
  end

  it "the handler stack does not leak state between independent guard/with-exception-handler blocks" do
    w(<<-SCM).should eq("(caught caught)")
      (define first
        (guard (e (#t 'caught))
          (with-exception-handler
            (lambda (e) 'inner-ignored-return)
            (lambda () (raise 'boom)))))
      (define second
        ; if the first block's handler leaked onto the stack, this raise
        ; would incorrectly reach it instead of unwinding straight to guard
        (guard (e (#t 'caught))
          (raise 'trigger)))
      (list first second)
    SCM
  end
end

describe "file-error?" do
  it "is true for a file-not-found error from (creme file)" do
    w(<<-SCM).should eq("is-file-error")
      (import (creme file))
      (guard (e ((file-error? e) 'is-file-error) (#t 'other))
        (file-read "/no/such/file/at/all.txt"))
    SCM
  end

  it "is false for an unrelated error" do
    w(%[(guard (e ((file-error? e) 'is-file-error) (#t 'other)) (error "not a file error"))]).should eq("other")
  end

  it "is false for a plain raised object" do
    w(%[(guard (e ((file-error? e) 'is-file-error) (#t 'other)) (raise 'x))]).should eq("other")
  end
end

describe "read-error?" do
  it "is true for malformed input reached through read" do
    w(<<-SCM).should eq("is-read-error")
      (import (scheme read))
      (guard (e ((read-error? e) 'is-read-error) (#t 'other))
        (read (open-input-string "(1 2")))
    SCM
  end

  it "is false for an unrelated error" do
    w(%[(guard (e ((read-error? e) 'is-read-error) (#t 'other)) (error "not a read error"))]).should eq("other")
  end

  it "does not misfire for a script's own (unrelated) parse errors" do
    expect_raises(Creme::SchemeParseError) { run(")") }
  end
end
