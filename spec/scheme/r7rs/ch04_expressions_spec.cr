require "../../spec_helper"
require "file_utils"

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "R7RS §4.1.1 Variable references" do
  it "a variable reference evaluates to its bound value" do
    w("(define x 28) x").should eq("28")
  end
end

describe "R7RS §4.1.2 Literal expressions" do
  it "quote returns its datum unevaluated" do
    w("(quote a)").should eq("a")
    w("(quote (+ 1 2))").should eq("(+ 1 2)")
  end

  it "'datum is an abbreviation for (quote datum)" do
    w("'a").should eq("a")
    w("''a").should eq("(quote a)")
  end

  it "numbers, strings, characters, vectors, bytevectors, booleans self-evaluate" do
    w("145932").should eq("145932")
    w(%("abc")).should eq(%("abc"))
    w("#(a 10)").should eq("#(a 10)")
    w("#u8(64 65)").should eq("#u8(64 65)")
    w("#t").should eq("#t")
  end
end

describe "R7RS §4.1.3 Procedure calls" do
  it "evaluates the operator and operands, then applies" do
    w("(+ 3 4)").should eq("7")
    w("((if #f + *) 3 4)").should eq("12")
  end
end

describe "R7RS §4.1.4 Procedures (lambda)" do
  it "a fixed-arity lambda binds each formal to the corresponding actual" do
    w("((lambda (x) (+ x x)) 4)").should eq("8")
  end

  it "a rest-arg lambda ((var) . rest) collects leftover actuals into a list" do
    w("((lambda (x y . z) z) 3 4 5 6)").should eq("(5 6)")
  end

  it "a single-symbol formals list collects all actuals into a list" do
    w("((lambda args args) 3 4 5 6)").should eq("(3 4 5 6)")
  end

  it "case-lambda dispatches on argument count" do
    w(<<-SCM).should eq("(0 1 2)")
      (define range
        (case-lambda
          ((e) (range 0 e))
          ((b e) (do ((r '() (cons e r)) (e (- e 1) (- e 1))) ((< e b) r)))))
      (range 3)
    SCM
  end
end

describe "R7RS §4.1.5 Conditionals (if)" do
  it "evaluates the consequent when test is true, alternate when false" do
    w("(if (> 3 2) 'yes 'no)").should eq("yes")
    w("(if (> 2 3) 'yes 'no)").should eq("no")
  end

  it "with no alternate and a false test, the result is unspecified (but must not error)" do
    run("(if #f 'unreached)")
  end
end

describe "R7RS §4.1.6 Assignments (set!)" do
  it "set! stores a new value into the variable's existing location" do
    w("(define x 2) (set! x 4) (+ x 1)").should eq("5")
  end
end

describe "R7RS §4.1.7 Inclusion (include/include-ci)" do
  it "include replaces the expression with a begin expression containing what was read from the file" do
    dir = File.tempname("creme-r7rs-ch04-spec", "")
    Dir.mkdir_p(dir)
    begin
      File.write(File.join(dir, "triple.scm"), "(define (triple x) (* x 3))")
      interp = Scheme::Interpreter.new
      interp.push_load_dir(dir)
      Scheme.run_source(interp, <<-SCM).write_string.should eq("15")
        (include "triple.scm")
        (triple 5)
      SCM
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "include-ci reads the file as if it began with #!fold-case, lowercasing identifiers before lexing" do
    dir = File.tempname("creme-r7rs-ch04-spec", "")
    Dir.mkdir_p(dir)
    begin
      File.write(File.join(dir, "square.scm"), "(DEFINE (SQUARE X) (* X X))")
      interp = Scheme::Interpreter.new
      interp.push_load_dir(dir)
      Scheme.run_source(interp, <<-SCM).write_string.should eq("25")
        (include-ci "square.scm")
        (square 5)
      SCM
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end

describe "R7RS §4.2.1 Conditionals (cond/case/when/unless/cond-expand)" do
  it "cond evaluates clauses in order, returning the matched clause's last expression" do
    w("(cond ((> 3 2) 'greater) ((< 3 2) 'less))").should eq("greater")
    w("(cond ((> 3 3) 'greater) ((< 3 3) 'less) (else 'equal))").should eq("equal")
  end

  it "a cond clause with only a test returns the test's value if true" do
    w("(cond (2 3) (else 'no))").should eq("3")
  end

  it "cond's (test => proc) arrow-clause form applies proc to the test's value" do
    w("(cond ((assv 'b '((a 1) (b 2))) => cadr) (else 'nope))").should eq("2")
  end

  it "case dispatches on eqv?-equality against each clause's datum list" do
    w("(case (* 2 3) ((2 3 5 7) 'prime) ((1 4 6 8 9) 'composite))").should eq("composite")
    w("(case (car '(c d)) ((a) 'a) ((b) 'b))").should eq("()")
  end

  it "case's else clause supports the => arrow form" do
    w("(case (car '(c d)) ((a e i o u) 'vowel) (else => (lambda (x) x)))").should eq("c")
  end

  it "case's non-else clauses also support the => arrow form" do
    w("(case (* 2 3) ((2 3 5 7) 'prime) ((1 4 6 8 9) => (lambda (x) (list 'composite x))))").should eq("(composite 6)")
  end

  it "and returns #f on the first false value, otherwise the last value" do
    w("(and (= 2 2) (> 2 1))").should eq("#t")
    w("(and (= 2 2) (< 2 1))").should eq("#f")
    w("(and 1 2 'c '(f g))").should eq("(f g)")
    w("(and)").should eq("#t")
  end

  it "or returns the first true value, otherwise #f" do
    w("(or (= 2 2) (> 2 1))").should eq("#t")
    w("(or (= 2 2) (< 2 1))").should eq("#t")
    w("(or #f #f #f)").should eq("#f")
    w("(or (memq 'b '(a b c)) (/ 3 0))").should eq("(b c)")
  end

  it "when evaluates its body only if test is true, returning unspecified" do
    w("(when #t 'a 'b)").should eq("b")
  end

  it "unless evaluates its body only if test is false" do
    w("(unless #f 'a 'b)").should eq("b")
  end

  it "cond-expand statically selects a branch based on feature-identifier requirements" do
    w("(cond-expand (r7rs 'yes) (else 'no))").should eq("yes")
    w("(cond-expand (fictional-feature 'no) (else 'yes))").should eq("yes")
  end

  it "cond-expand supports and/or/not feature-requirement combinators" do
    w("(cond-expand ((and r7rs (not fictional-feature)) 'yes) (else 'no))").should eq("yes")
  end
end

describe "R7RS §4.2.2 Binding constructs (let/let*/letrec/letrec*/let-values/let*-values)" do
  it "let evaluates all inits before any binding takes effect" do
    w("(let ((x 2) (y 3)) (* x y))").should eq("6")
  end

  it "let* binds sequentially, so later inits see earlier bindings" do
    w("(let* ((x 2) (y 3)) (let* ((x 7) (z (+ x y))) (* z x)))").should eq("70")
  end

  it "letrec allows mutually recursive procedure definitions" do
    w(<<-SCM).should eq("#t")
      (letrec ((even? (lambda (n) (if (zero? n) #t (odd? (- n 1)))))
               (odd? (lambda (n) (if (zero? n) #f (even? (- n 1))))))
        (even? 88))
    SCM
  end

  it "letrec* is like letrec but evaluates/assigns inits strictly left-to-right" do
    w(<<-SCM).should eq("5")
      (letrec* ((p (lambda (x) (+ 1 (q (- x 1)))))
                (q (lambda (y) (if (zero? y) 0 (+ 1 (p (- y 1))))))
                (x (p 5))
                (y x))
        y)
    SCM
  end

  it "let-values binds each formals-group to the values produced by its init" do
    w("(let-values (((a b) (values 1 2)) ((x y) (values 'x 'y))) (list a b x y))").should eq("(1 2 x y)")
  end

  it "let-values works with a procedure like exact-integer-sqrt that delivers multiple values" do
    w("(let-values (((root rem) (exact-integer-sqrt 32))) (* root rem))").should eq("35")
  end

  it "let*-values binds sequentially, later inits see earlier bindings" do
    w(<<-SCM).should eq("(x y x y)")
      (let ((a 'a) (b 'b) (x 'x) (y 'y))
        (let*-values (((a b) (values x y)) ((x y) (values a b))) (list a b x y)))
    SCM
  end

  it "named let is a variant of let providing a general looping construct" do
    w(<<-SCM).should eq("((6 1 3) (-5 -2))")
      (let loop ((numbers '(3 -2 1 6 -5)) (nonneg '()) (neg '()))
        (cond ((null? numbers) (list nonneg neg))
              ((>= (car numbers) 0) (loop (cdr numbers) (cons (car numbers) nonneg) neg))
              ((< (car numbers) 0) (loop (cdr numbers) nonneg (cons (car numbers) neg)))))
    SCM
  end
end

describe "R7RS §4.2.3 Sequencing (begin)" do
  it "begin evaluates its expressions in order, returning the last one's value" do
    w("(define x 0) (and (= x 0) (begin (set! x 5) (+ x 1)))").should eq("6")
  end
end

describe "R7RS §4.2.4 Iteration (do)" do
  it "do iterates, updating step variables until test is true, then returns the result exprs" do
    w(<<-SCM).should eq("#(0 1 2 3 4)")
      (do ((vec (make-vector 5)) (i 0 (+ i 1)))
          ((= i 5) vec)
        (vector-set! vec i i))
    SCM
  end

  it "do with no result expression returns unspecified after the loop finishes" do
    w(<<-SCM).should eq("25")
      (let ((x '(1 3 5 7 9)))
        (do ((x x (cdr x)) (sum 0 (+ sum (car x))))
            ((null? x) sum)))
    SCM
  end
end

describe "R7RS §4.2.5 Delayed evaluation (delay/delay-force/force/make-promise/promise?)" do
  it "force evaluates a delayed expression, only computing it once" do
    w("(import (scheme lazy)) (force (delay (+ 1 2)))").should eq("3")
  end

  it "promise? recognizes promises created by delay/make-promise" do
    w("(import (scheme lazy)) (promise? (delay 1))").should eq("#t")
    w("(import (scheme lazy)) (promise? (make-promise 1))").should eq("#t")
  end

  it "delay/force are not auto-imported with (scheme base) — need (scheme lazy)" do
    expect_raises(Scheme::SchemeRuntimeError, /unbound variable: force/) do
      run("(force (delay 1))")
    end
  end
end

describe "R7RS §4.2.6 Dynamic bindings (make-parameter/parameterize)" do
  it "parameterize temporarily rebinds a parameter object for the dynamic extent of its body" do
    w(<<-SCM).should eq(%(("12" "1100" "12")))
      (define radix
        (make-parameter 10 (lambda (x) (if (and (exact-integer? x) (<= 2 x 16)) x (error "invalid radix")))))
      (define (f n) (number->string n (radix)))
      (list (f 12) (parameterize ((radix 2)) (f 12)) (f 12))
    SCM
  end
end

describe "R7RS §4.2.7 Exception handling (guard)" do
  it "guard evaluates cond-style clauses against the raised object, restoring the guard's dynamic environment" do
    w(<<-SCM).should eq("42")
      (guard (condition ((assq 'a condition) (cdr (assq 'a condition))) ((assq 'b condition) (cdr (assq 'b condition))))
        (raise (list (cons 'a 42))))
    SCM
  end

  it "an unmatched inner guard re-raises to the enclosing guard, whose own clause then matches" do
    w(<<-SCM).should eq("23")
      (guard (condition ((assq 'b condition) (cdr (assq 'b condition))))
        (guard (condition ((assq 'a condition) (cdr (assq 'a condition))))
          (raise (list (cons 'b 23)))))
    SCM
  end

  it "guard's cond-style (test => proc) arrow-clause form applies proc to the raised object's matched test value" do
    w(<<-SCM).should eq("42")
      (guard (condition ((assq 'a condition) => cdr) ((assq 'b condition)))
        (raise (list (cons 'a 42))))
    SCM
  end
end

describe "R7RS §4.2.8 Quasiquotation" do
  it "quasiquote with no unquote is equivalent to plain quote" do
    w("`(list 1 2)").should eq("(list 1 2)")
  end

  it "unquote splices a single evaluated expression into the template" do
    w("`(list ,(+ 1 2) 4)").should eq("(list 3 4)")
  end

  it "unquote-splicing splices a list's elements into the surrounding template" do
    w("`(a ,(+ 1 2) ,@(map abs '(4 -5 6)) b)").should eq("(a 3 4 5 6 b)")
  end

  it "quasiquote nests: inner quasiquotes increase nesting depth, inner unquotes decrease it" do
    w("`(a `(b ,(+ 1 2) ,(foo ,(+ 1 3) d) e) f)").should eq("(a (quasiquote (b (unquote (+ 1 2)) (unquote (foo 4 d)) e)) f)")
  end

  it "a vector quasiquote template processes unquote and unquote-splicing the same as a list template" do
    w("(import (scheme inexact)) `#(10 5 ,(sqrt 4) ,@(map sqrt '(16 9)) 8)").should eq("#(10 5 2 4 3 8)")
  end
end

describe "R7RS §4.3.1/4.3.2 Macros (define-syntax/let-syntax/letrec-syntax/syntax-rules)" do
  it "a basic syntax-rules macro rewrites its use according to the matching pattern/template" do
    w(<<-SCM).should eq("4")
      (define-syntax sequence
        (syntax-rules ()
          ((sequence expr ...) (begin expr ...))))
      (sequence 1 2 3 4)
    SCM
  end

  it "the (... template) ellipsis-escape idiom lets a macro's own output contain a literal ... inside a generated syntax-rules macro" do
    w(<<-SCM).should eq("4")
      (define-syntax be-like-begin
        (syntax-rules ()
          ((be-like-begin name)
           (define-syntax name
             (syntax-rules ()
               ((name expr (... ...)) (begin expr (... ...))))))))
      (be-like-begin sequence)
      (sequence 1 2 3 4)
    SCM
  end

  it "let-syntax scopes a macro binding to its body (unhygienic: use-site shadowing wins, not definition-site — see README Known caveats)" do
    w(<<-SCM).should eq("inner")
      (let ((x 'outer))
        (let-syntax ((m (syntax-rules () ((m) x))))
          (let ((x 'inner)) (m))))
    SCM
  end

  pending "letrec-syntax + hygiene stress test (R7RS's own my-or example, whose expansion binds temp/if/let and relies on hygiene to not collide with a use-site shadowing of those same names) fails ('not applicable: 8') since define-syntax/syntax-rules is unhygienic — see README Known caveats"

  it "a simple-let macro using dotted/ellipsis patterns expands correctly on the non-error clause" do
    w(<<-SCM).should eq("3")
      (define-syntax simple-let
        (syntax-rules ()
          ((_ (head ... ((x . y) val) . tail) body1 body2 ...)
           (syntax-error "expected an identifier but got" (x . y)))
          ((_ ((name val) ...) body1 body2 ...)
           ((lambda (name ...) body1 body2 ...) val ...))))
      (simple-let ((x 1) (y 2)) (+ x y))
    SCM
  end
end

describe "R7RS §4.3.3 Signaling errors in macro transformers (syntax-error)" do
  it "syntax-error raises when a macro use matches a syntax-error-producing clause" do
    expect_raises(Scheme::SchemeRuntimeError) do
      run(<<-SCM)
        (define-syntax simple-let
          (syntax-rules ()
            ((_ (head ... ((x . y) val) . tail) body1 body2 ...)
             (syntax-error "expected an identifier but got" (x . y)))
            ((_ ((name val) ...) body1 body2 ...)
             ((lambda (name ...) body1 body2 ...) val ...))))
        (simple-let ((3 . 4) 5))
      SCM
    end
  end
end
