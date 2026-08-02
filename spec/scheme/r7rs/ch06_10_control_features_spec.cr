require "../../spec_helper"

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "R7RS §6.10 Control features" do
  it "procedure? is #t for procedures, #f otherwise" do
    w("(procedure? car)").should eq("#t")
    w("(procedure? 'car)").should eq("#f")
    w("(procedure? (lambda (x) (* x x)))").should eq("#t")
  end

  it "apply calls proc with the elements of the argument lists appended together" do
    w("(apply + (list 3 4))").should eq("7")
    w(<<-SCM).should eq("30")
      (import (scheme inexact))
      (define (compose f g) (lambda args (f (apply g args))))
      ((compose sqrt *) 12 75)
    SCM
  end

  it "map applies proc element-wise to one or more lists, terminating on the shortest" do
    w("(map cadr '((a b) (d e) (g h)))").should eq("(b e h)")
    w("(map (lambda (n) (expt n n)) '(1 2 3 4 5))").should eq("(1 4 27 256 3125)")
    w("(map + '(1 2 3) '(4 5 6))").should eq("(5 7 9)")
  end

  it "for-each is like map but calls proc for side effects, guaranteed left-to-right" do
    w(<<-SCM).should eq("#(0 1 4 9 16)")
      (define v (make-vector 5))
      (for-each (lambda (i) (vector-set! v i (* i i))) '(0 1 2 3 4))
      v
    SCM
  end

  it "call-with-current-continuation packages the current continuation as an escape procedure" do
    w(<<-SCM).should eq("-3")
      (call-with-current-continuation
        (lambda (exit)
          (for-each (lambda (x) (if (negative? x) (exit x))) '(54 0 37 -3 245 19))
          #t))
    SCM
  end

  it "call/cc is a synonym for call-with-current-continuation" do
    w(<<-SCM).should eq("(4 #f)")
      (define (list-length obj)
        (call/cc
          (lambda (return)
            (letrec ((r (lambda (obj)
                          (cond ((null? obj) 0)
                                ((pair? obj) (+ (r (cdr obj)) 1))
                                (else (return #f))))))
              (r obj)))))
      (list (list-length '(1 2 3 4)) (list-length '(a b . c)))
    SCM
  end

  pending "call/cc implements escape continuations only, via a Crystal exception unwind — not full R7RS multi-shot/re-entrant continuations (see README Known caveats). Re-invoking a captured continuation after its call/cc has already returned raises 'continuation invoked outside its dynamic extent' instead of resuming: (define k #f) (+ 1 (call/cc (lambda (c) (set! k c) 1))) followed by (k 2) fails on the second call rather than re-entering and yielding 3"

  it "values delivers all of its arguments to its continuation" do
    w("(call-with-values (lambda () (values 4 5)) (lambda (a b) b))").should eq("5")
  end

  it "call-with-values calls producer with no arguments, then applies consumer to the resulting values" do
    w("(call-with-values (lambda () (values 4 5)) +)").should eq("9")
    w("(call-with-values * -)").should eq("-1")
  end

  it "dynamic-wind calls thunk, guaranteeing before/after run exactly once each around normal return" do
    w(<<-SCM).should eq("(enter exit)")
      (define log '())
      (dynamic-wind
        (lambda () (set! log (cons 'enter log)))
        (lambda () 'body-result)
        (lambda () (set! log (cons 'exit log))))
      (reverse log)
    SCM
  end

  it "dynamic-wind's before/after also run around a call/cc escape past the dynamic-wind call" do
    w(<<-SCM).should eq("(enter done exit)")
      (define log '())
      (define (record! s) (set! log (cons s log)))
      (call/cc (lambda (k)
        (dynamic-wind
          (lambda () (record! 'enter))
          (lambda () (k (begin (record! 'done) 'done)))
          (lambda () (record! 'exit)))))
      (reverse log)
    SCM
  end
end
