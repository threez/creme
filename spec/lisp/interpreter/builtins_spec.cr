require "../../spec_helper"

private def w(src : String) : String
  interp = LISP::Interpreter.new
  LISP.run_source(interp, src).write_string
end

describe "builtins: arithmetic" do
  it "+ sums with no args returning 0" do
    w("(+)").should eq("0")
  end

  it "+ sums ints" do
    w("(+ 1 2 3)").should eq("6")
  end

  it "+ promotes to float when any operand is a float" do
    w("(+ 1 2.5 3)").should eq("6.5")
  end

  it "* multiplies with no args returning 1" do
    w("(*)").should eq("1")
  end

  it "* multiplies ints" do
    w("(* 2 3 4)").should eq("24")
  end

  it "- negates a single argument" do
    w("(- 5)").should eq("-5")
  end

  it "- subtracts left to right" do
    w("(- 10 1 2)").should eq("7")
  end

  it "/ inverts a single argument" do
    interp = LISP::Interpreter.new
    LISP.run_source(interp, "(/ 2)").write_string.should eq("0.5")
  end

  it "/ divides evenly to an int" do
    w("(/ 10 2)").should eq("5")
  end

  it "/ divides unevenly to a float" do
    w("(/ 1 4)").should eq("0.25")
  end

  it "/ raises on division by zero" do
    expect_raises(LISP::LispRuntimeError, /division by zero/) { w("(/ 1 0)") }
  end

  it "modulo computes the modulus" do
    w("(modulo 7 3)").should eq("1")
  end

  it "modulo raises on zero divisor" do
    expect_raises(LISP::LispRuntimeError, /modulo: division by zero/) { w("(modulo 1 0)") }
  end

  it "remainder computes the remainder" do
    w("(remainder -7 3)").should eq("-1")
  end

  it "remainder raises on zero divisor" do
    expect_raises(LISP::LispRuntimeError, /remainder: division by zero/) { w("(remainder 1 0)") }
  end

  it "quotient truncates toward zero" do
    w("(quotient -7 2)").should eq("-3")
  end

  it "quotient raises on zero divisor" do
    expect_raises(LISP::LispRuntimeError, /quotient: division by zero/) { w("(quotient 1 0)") }
  end

  it "abs handles ints and floats" do
    w("(abs -5)").should eq("5")
    w("(abs -5.5)").should eq("5.5")
  end

  it "abs raises for a non-number" do
    expect_raises(LISP::LispRuntimeError, /abs: expected number/) { w(%((abs "x"))) }
  end

  it "min returns the smallest" do
    w("(min 3 1 2)").should eq("1")
  end

  it "min promotes to float if any arg is a float" do
    w("(min 3 1.0 2)").should eq("1.0")
  end

  it "max returns the largest" do
    w("(max 3 1 2)").should eq("3")
  end

  it "expt computes integer powers" do
    w("(expt 2 10)").should eq("1024")
  end

  it "expt computes float powers for negative exponents" do
    w("(expt 2 -1)").should eq("0.5")
  end

  it "sqrt computes a float square root" do
    w("(sqrt 16)").should eq("4.0")
  end
end

describe "builtins: comparisons" do
  it "= chains equality" do
    w("(= 1 1 1)").should eq("#t")
    w("(= 1 1 2)").should eq("#f")
  end

  it "< chains strictly increasing" do
    w("(< 1 2 3)").should eq("#t")
    w("(< 1 3 2)").should eq("#f")
  end

  it "> chains strictly decreasing" do
    w("(> 3 2 1)").should eq("#t")
  end

  it "<= allows equal neighbors" do
    w("(<= 1 1 2)").should eq("#t")
  end

  it ">= allows equal neighbors" do
    w("(>= 2 2 1)").should eq("#t")
  end

  it "not inverts truthiness" do
    w("(not #f)").should eq("#t")
    w("(not 1)").should eq("#f")
  end
end

describe "builtins: equality" do
  it "eq? / eqv? compare by identity-ish value semantics" do
    w("(eq? 'a 'a)").should eq("#t")
    w("(eqv? 1 1)").should eq("#t")
  end

  it "equal? deeply compares structures" do
    w("(equal? (list 1 (list 2 3)) (list 1 (list 2 3)))").should eq("#t")
  end
end

describe "builtins: pairs & lists" do
  it "cons builds a pair" do
    w("(cons 1 2)").should eq("(1 . 2)")
  end

  it "car/cdr access pair fields" do
    w("(car (cons 1 2))").should eq("1")
    w("(cdr (cons 1 2))").should eq("2")
  end

  it "car raises for a non-pair" do
    expect_raises(LISP::LispRuntimeError, /car: expected pair/) { w("(car 1)") }
  end

  it "cdr raises for a non-pair" do
    expect_raises(LISP::LispRuntimeError, /cdr: expected pair/) { w("(cdr 1)") }
  end

  it "set-car!/set-cdr! mutate in place" do
    w("(define p (cons 1 2)) (set-car! p 9) (set-cdr! p 8) p").should eq("(9 . 8)")
  end

  it "set-car! raises for a non-pair" do
    expect_raises(LISP::LispRuntimeError, /set-car!: expected pair/) { w("(set-car! 1 2)") }
  end

  it "set-cdr! raises for a non-pair" do
    expect_raises(LISP::LispRuntimeError, /set-cdr!: expected pair/) { w("(set-cdr! 1 2)") }
  end

  it "list builds a list from its args" do
    w("(list 1 2 3)").should eq("(1 2 3)")
  end

  it "append concatenates lists" do
    w("(append '(1 2) '(3 4))").should eq("(1 2 3 4)")
  end

  it "append with no args returns nil" do
    w("(append)").should eq("()")
  end

  it "length counts elements" do
    w("(length '(a b c))").should eq("3")
  end

  it "reverse reverses a list" do
    w("(reverse '(1 2 3))").should eq("(3 2 1)")
  end

  it "list-ref indexes into a list" do
    w("(list-ref '(a b c) 1)").should eq("b")
  end

  it "list-ref raises out of range" do
    expect_raises(LISP::LispRuntimeError, /list-ref: index 5 out of range/) { w("(list-ref '(a b c) 5)") }
  end

  it "null? tests for the empty list" do
    w("(null? '())").should eq("#t")
    w("(null? '(1))").should eq("#f")
  end

  it "pair? tests for a cons cell" do
    w("(pair? (cons 1 2))").should eq("#t")
    w("(pair? '())").should eq("#f")
  end

  it "list? tests for a proper list" do
    w("(list? '(1 2))").should eq("#t")
    w("(list? (cons 1 2))").should eq("#f")
  end
end

describe "builtins: higher-order" do
  it "map applies a function across one list" do
    w("(map (lambda (x) (* x x)) '(1 2 3))").should eq("(1 4 9)")
  end

  it "map supports multiple lists" do
    w("(map + '(1 2 3) '(10 20 30))").should eq("(11 22 33)")
  end

  it "filter keeps matching elements" do
    w("(filter (lambda (x) (> x 2)) '(1 2 3 4))").should eq("(3 4)")
  end

  it "reduce folds from the left with a seed" do
    w("(reduce + 0 '(1 2 3 4 5))").should eq("15")
  end

  it "foldl folds left to right" do
    w("(foldl cons '() '(1 2 3))").should eq("(((() . 1) . 2) . 3)")
  end

  it "foldr folds right to left" do
    w("(foldr cons '() '(1 2 3))").should eq("(1 2 3)")
  end

  it "for-each evaluates for side effects and returns nil" do
    w("(define sum 0) (for-each (lambda (x) (set! sum (+ sum x))) '(1 2 3)) sum").should eq("6")
  end

  it "apply spreads a trailing list of args" do
    w("(apply + 1 2 '(3 4))").should eq("10")
  end
end

describe "builtins: type predicates" do
  it "number?/integer?/float?/real?" do
    w("(number? 1)").should eq("#t")
    w("(integer? 1)").should eq("#t")
    w("(float? 1.0)").should eq("#t")
    w("(real? 1.0)").should eq("#t")
    w("(integer? 1.0)").should eq("#f")
  end

  it "symbol?/string?/boolean?/char?/procedure?" do
    w("(symbol? 'a)").should eq("#t")
    w("(string? \"a\")").should eq("#t")
    w("(boolean? #t)").should eq("#t")
    w("(char? #\\a)").should eq("#t")
    w("(procedure? car)").should eq("#t")
    w("(procedure? (lambda (x) x))").should eq("#t")
    w("(procedure? 1)").should eq("#f")
  end

  it "macro?" do
    w("(defmacro m (x) x) (macro? m)").should eq("#t")
    w("(macro? car)").should eq("#f")
  end
end

describe "builtins: macros" do
  it "gensym returns a fresh symbol each call" do
    w("(symbol? (gensym))").should eq("#t")
    w("(eq? (gensym) (gensym))").should eq("#f")
  end

  it "gensym honors an optional prefix" do
    w(%((symbol->string (gensym "tmp")))).should match(/^"tmp__\d+"$/)
  end

  it "gensym defaults to a \"g\" prefix" do
    w("(symbol->string (gensym))").should match(/^"g__\d+"$/)
  end
end

describe "builtins: strings" do
  it "string-append concatenates" do
    w(%((string-append "a" "b" "c"))).should eq(%("abc"))
  end

  it "string-append raises for a non-string" do
    expect_raises(LISP::LispRuntimeError, /string-append: expected string/) { w(%((string-append "a" 1))) }
  end

  it "string-length counts characters" do
    w(%((string-length "hello"))).should eq("5")
  end

  it "substring extracts a range" do
    w(%((substring "hello" 1 3))).should eq(%("el"))
  end

  it "substring defaults the end to the string length" do
    w(%((substring "hello" 2))).should eq(%("llo"))
  end

  it "substring raises out of range" do
    expect_raises(LISP::LispRuntimeError, /substring: index out of range/) { w(%((substring "hi" 0 5))) }
  end

  it "string->symbol converts" do
    w(%((string->symbol "foo"))).should eq("foo")
  end

  it "symbol->string converts" do
    w("(symbol->string 'foo)").should eq(%("foo"))
  end

  it "number->string converts numbers" do
    w("(number->string 42)").should eq(%("42"))
    w("(number->string 4.0)").should eq(%("4.0"))
  end

  it "string->number parses ints and floats" do
    w(%((string->number "42"))).should eq("42")
    w(%((string->number "3.5"))).should eq("3.5")
  end

  it "string->number returns #f for unparsable text" do
    w(%((string->number "abc"))).should eq("#f")
  end

  it "string=? compares multiple strings" do
    w(%((string=? "a" "a" "a"))).should eq("#t")
    w(%((string=? "a" "a" "b"))).should eq("#f")
  end
end

describe "builtins: I/O" do
  it "display/write/newline/print/println return nil" do
    w("(display 1)").should eq("()")
    w("(write 1)").should eq("()")
    w("(newline)").should eq("()")
    w("(print 1)").should eq("()")
    w("(println 1)").should eq("()")
  end
end

describe "builtins: misc" do
  it "error raises LispUserError with the joined message" do
    expect_raises(LISP::LispUserError, /boom 1 2/) do
      w("(error \"boom\" 1 2)")
    end
  end

  it "error raises LispRuntimeError (superclass)" do
    expect_raises(LISP::LispRuntimeError) do
      w(%((error "boom")))
    end
  end
end

describe "builtins: vectors" do
  it "vector builds a vector from its arguments" do
    w("(vector 1 2 3)").should eq("#(1 2 3)")
    w("(vector)").should eq("#()")
  end

  it "make-vector fills with nil by default, or a given fill value" do
    w("(make-vector 3)").should eq("#(() () ())")
    w(%((make-vector 3 "x"))).should eq(%(#("x" "x" "x")))
  end

  it "make-vector raises on a negative size" do
    expect_raises(LISP::LispRuntimeError, /make-vector: size must be non-negative/) do
      w("(make-vector -1)")
    end
  end

  it "vector-ref reads an element" do
    w("(vector-ref (vector 1 2 3) 1)").should eq("2")
  end

  it "vector-ref raises out of range" do
    expect_raises(LISP::LispRuntimeError, /vector-ref: index 5 out of range/) do
      w("(vector-ref (vector 1 2 3) 5)")
    end
  end

  it "vector-set! mutates in place" do
    w("(define v (vector 1 2 3)) (vector-set! v 0 99) v").should eq("#(99 2 3)")
  end

  it "vector-set! raises out of range" do
    expect_raises(LISP::LispRuntimeError, /vector-set!: index -1 out of range/) do
      w("(vector-set! (vector 1 2 3) -1 0)")
    end
  end

  it "vector-length reports element count" do
    w("(vector-length (vector 1 2 3))").should eq("3")
  end

  it "vector? distinguishes vectors from lists" do
    w("(vector? (vector 1 2))").should eq("#t")
    w("(vector? (list 1 2))").should eq("#f")
  end

  it "vector->list and list->vector convert between the two" do
    w("(vector->list (vector 1 2 3))").should eq("(1 2 3)")
    w("(list->vector (list 1 2 3))").should eq("#(1 2 3)")
  end

  it "equal? compares vectors structurally" do
    w("(equal? (vector 1 2 3) (vector 1 2 3))").should eq("#t")
    w("(equal? (vector 1 2 3) (vector 1 2 4))").should eq("#f")
  end

  it "eq?/eqv? compare vectors by identity" do
    w("(define v (vector 1 2 3)) (eq? v v)").should eq("#t")
    w("(eq? (vector 1 2 3) (vector 1 2 3))").should eq("#f")
  end
end
