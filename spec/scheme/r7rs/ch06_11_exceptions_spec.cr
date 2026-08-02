require "../../spec_helper"

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "R7RS §6.11 Exceptions" do
  it "with-exception-handler installs handler as the current exception handler for thunk's invocation" do
    w(<<-SCM).should eq(%(("condition:" an-error)))
      (call-with-current-continuation
        (lambda (k)
          (with-exception-handler
            (lambda (x) (k (list "condition:" x)))
            (lambda ()
              (+ 1 (raise 'an-error))))))
    SCM
  end

  it "raise-continuable invokes the handler, whose return value flows back as raise-continuable's result" do
    w(<<-SCM).should eq("65")
      (with-exception-handler
        (lambda (con) 42)
        (lambda ()
          (+ (raise-continuable "should be a number") 23)))
    SCM
  end

  it "raise invokes the current exception handler on obj, using a non-continuable exception" do
    w(<<-SCM).should eq(%("caught: boom"))
      (call/cc (lambda (k)
        (with-exception-handler
          (lambda (e) (k (string-append "caught: " e)))
          (lambda () (raise "boom")))))
    SCM
  end

  it "guard evaluates cond-style clauses against the raised object" do
    w(<<-SCM).should eq("42")
      (guard (condition ((assq 'a condition) (cdr (assq 'a condition)))
                         ((assq 'b condition)))
        (raise (list (cons 'a 42))))
    SCM
  end

  it "a guard clause with only a test (no body) returns the test's own value, per cond semantics" do
    w(<<-SCM).should eq("(b . 23)")
      (guard (condition ((assq 'a condition) (cdr (assq 'a condition)))
                         ((assq 'b condition)))
        (raise (list (cons 'b 23))))
    SCM
  end

  it "error raises an exception encapsulating a message and irritants" do
    w(<<-SCM).should eq(%("null-list?: argument out of domain"))
      (define (null-list? l)
        (cond ((pair? l) #f)
              ((null? l) #t)
              (else (error "null-list?: argument out of domain" l))))
      (guard (e (#t (error-object-message e))) (null-list? 5))
    SCM
  end

  it "error-object-irritants returns the list of irritants passed to error" do
    w(%[(guard (e (#t (error-object-irritants e))) (error "boom" 1 2 3))]).should eq("(1 2 3)")
  end

  it "error-object? is #t for objects created by error, #f for arbitrary raised objects" do
    w(%[(guard (e ((error-object? e) 'is-obj) (#t 'is-not-obj)) (error "x"))]).should eq("is-obj")
    w("(guard (e ((error-object? e) 'is-obj) (#t 'is-not-obj)) (raise 'my-symbol))").should eq("is-not-obj")
  end

  it "raise/guard work with any object, not just error-object?-satisfying ones" do
    w("(guard (e ((symbol? e) e)) (raise 'my-symbol))").should eq("my-symbol")
  end

  it "read-error?/file-error? are #f for an arbitrary raised object" do
    w("(guard (e ((read-error? e) 'read-err) (#t 'other)) (raise 'my-symbol))").should eq("other")
    w("(guard (e ((file-error? e) 'file-err) (#t 'other)) (raise 'my-symbol))").should eq("other")
  end

  it "guard's cond-style (test => proc) arrow-clause form applies proc to the matched test value" do
    w("(guard (e ((assq 'a e) => cdr) (#t 'other)) (raise (list (cons 'a 42))))").should eq("42")
  end
end
