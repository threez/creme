require "../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (scheme base) (creme lr)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (scheme base) (creme lr)) #{src}")
end

# A tiny tiered-precedence arithmetic grammar, shared by several examples
# below (mirrors (creme lr)'s own header-comment example):
#   expr -> add-expr
#   add-expr -> add-expr '+ mul-expr | mul-expr
#   mul-expr -> mul-expr '* num | num
private ARITH_GRAMMAR = <<-SCHEME
  (define g
    (make-grammar 'expr
      (list (make-rule 'expr (list 'add-expr) (lambda (v) v))
            (make-rule 'add-expr (list 'add-expr 'plus 'mul-expr) (lambda (a p b) (+ a b)))
            (make-rule 'add-expr (list 'mul-expr) (lambda (v) v))
            (make-rule 'mul-expr (list 'mul-expr 'star 'num) (lambda (a s b) (* a b)))
            (make-rule 'mul-expr (list 'num) (lambda (v) v)))))
  (define pt (build-parser g))
  (define (tok kind value) (cons kind value))
  SCHEME

describe "(creme lr)" do
  it "parses a single terminal grammar" do
    w(<<-SCHEME).should eq("42")
      #{ARITH_GRAMMAR}
      (lr-parse pt (list (tok 'num 42)) car cdr)
      SCHEME
  end

  it "respects tiered precedence: * binds tighter than +" do
    w(<<-SCHEME).should eq("14")
      #{ARITH_GRAMMAR}
      (lr-parse pt (list (tok 'num 2) (tok 'plus #f) (tok 'num 3) (tok 'star #f) (tok 'num 4)) car cdr)
      SCHEME
  end

  it "left-recursive add-expr is left-associative" do
    w(<<-SCHEME).should eq("9")
      #{ARITH_GRAMMAR}
      (lr-parse pt (list (tok 'num 2) (tok 'plus #f) (tok 'num 3) (tok 'plus #f) (tok 'num 4)) car cdr)
      SCHEME
  end

  it "handles an epsilon production (a possibly-empty repeated clause)" do
    w(<<-SCHEME).should eq("3")
      (define g
        (make-grammar 'as
          (list (make-rule 'as (list 'a 'as) (lambda (x rest) (+ 1 rest)))
                (make-rule 'as (list) (lambda () 0)))))
      (define pt (build-parser g))
      (lr-parse pt (list (cons 'a #f) (cons 'a #f) (cons 'a #f)) car cdr)
      SCHEME
    w(<<-SCHEME).should eq("0")
      (define g
        (make-grammar 'as
          (list (make-rule 'as (list 'a 'as) (lambda (x rest) (+ 1 rest)))
                (make-rule 'as (list) (lambda () 0)))))
      (define pt (build-parser g))
      (lr-parse pt (list) car cdr)
      SCHEME
  end

  it "build-parser raises on a shift/reduce conflict instead of guessing" do
    expect_raises(Scheme::SchemeRuntimeError, /conflict/) do
      run(<<-SCHEME)
        ;; classic dangling-"else"-shaped ambiguity: a flat, non-tiered
        ;; `expr -> expr op expr | num` is genuinely ambiguous (no precedence
        ;; declarations exist in this library to resolve it), so build-parser
        ;; must fail loudly rather than pick shift or reduce arbitrarily.
        (define g
          (make-grammar 'expr
            (list (make-rule 'expr (list 'expr 'plus 'expr) (lambda (a p b) (+ a b)))
                  (make-rule 'expr (list 'num) (lambda (v) v)))))
        (build-parser g)
        SCHEME
    end
  end

  it "lr-parse raises on an unexpected token" do
    expect_raises(Scheme::SchemeRuntimeError, /unexpected token/) do
      run(<<-SCHEME)
        #{ARITH_GRAMMAR}
        (lr-parse pt (list (tok 'plus #f)) car cdr)
        SCHEME
    end
  end
end
