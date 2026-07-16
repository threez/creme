require "../../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, "(import (creme prof-vm)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, "(import (creme prof-vm)) #{src}")
end

describe "prof-vm module" do
  it "profile-scheme returns a profile-scheme-report?" do
    w(<<-SCM).should eq("#t")
      (define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
      (profile-scheme-report? (profile-scheme (lambda () (fib 22)) 50))
    SCM
  end

  it "attributes samples across if/primitives/the call itself, not one entry" do
    # Regression test: samples used to be attributed to the innermost named
    # @call_stack frame, which always collapsed to a single entry ("fib") for
    # a recursive function — no visibility into if/+/-/</the call itself.
    # Node-level attribution should show several distinct labels.
    w(<<-SCM).should eq("#t")
      (define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
      (define report (profile-scheme (lambda () (fib 25)) 50))
      (define names (map (lambda (e) (cdr (car e))) (profile-scheme-top report 20)))
      (and (> (length names) 3)
           (if (member "(fib (- n 1))" names) #t #f))
    SCM
  end

  it "reconstructs source text, an instruction kind, and a file/line for a call site" do
    w(<<-SCM).should eq("#t")
      (define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
      (define report (profile-scheme (lambda () (fib 25)) 50))
      (define entries (profile-scheme-top report 20))
      (define (find-entry es)
        (cond ((null? es) #f)
              ((string=? (cdr (assoc "name" (car es) string=?)) "(fib (- n 1))") (car es))
              (else (find-entry (cdr es)))))
      (define call-entry (find-entry entries))
      (and call-entry
           (string=? (cdr (assoc "instruction" call-entry string=?)) "call")
           (string? (cdr (assoc "file" call-entry string=?)))
           (integer? (cdr (assoc "line" call-entry string=?))))
    SCM
  end

  it "labels a control construct's instruction in the language's own syntax" do
    w(<<-SCM).should eq("#t")
      (define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
      (define report (profile-scheme (lambda () (fib 25)) 50))
      (define entries (profile-scheme-top report 20))
      (define (find-if es)
        (cond ((null? es) #f)
              ((string=? (cdr (assoc "instruction" (car es) string=?)) "if") (car es))
              (else (find-if (cdr es)))))
      (if (find-if entries) #t #f)
    SCM
  end

  it "returns a valid report for a trivial thunk" do
    w("(profile-scheme-report? (profile-scheme (lambda () 42) 50))").should eq("#t")
  end

  it "propagates a raised error and still leaves sampling in a clean state" do
    interp = Scheme::Interpreter.new
    Scheme.run_source(interp, "(import (creme prof-vm))")

    expect_raises(Scheme::SchemeRuntimeError, /boom/) do
      Scheme.run_source(interp, %((profile-scheme (lambda () (error "boom")) 50)))
    end

    Scheme.run_source(interp, <<-SCM).write_string.should eq("#t")
      (define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
      (profile-scheme-report? (profile-scheme (lambda () (fib 20)) 50))
    SCM
  end
end
