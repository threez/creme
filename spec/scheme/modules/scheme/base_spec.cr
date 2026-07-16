require "../../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, src).write_string
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
    interp = Scheme::Interpreter.new
    Scheme.run_source(interp, "(/ 2)").write_string.should eq("1/2")
  end

  it "/ divides evenly to an int" do
    w("(/ 10 2)").should eq("5")
  end

  it "/ divides exact/exact unevenly to an exact rational, not a float" do
    w("(/ 1 4)").should eq("1/4")
  end

  it "/ divides a float to an inexact result" do
    w("(/ 1.0 4)").should eq("0.25")
  end

  it "/ raises on division by zero" do
    expect_raises(Scheme::SchemeRuntimeError, /division by zero/) { w("(/ 1 0)") }
  end

  it "modulo computes the modulus" do
    w("(modulo 7 3)").should eq("1")
  end

  it "modulo raises on zero divisor" do
    expect_raises(Scheme::SchemeRuntimeError, /modulo: division by zero/) { w("(modulo 1 0)") }
  end

  it "remainder computes the remainder" do
    w("(remainder -7 3)").should eq("-1")
  end

  it "remainder raises on zero divisor" do
    expect_raises(Scheme::SchemeRuntimeError, /remainder: division by zero/) { w("(remainder 1 0)") }
  end

  it "quotient truncates toward zero" do
    w("(quotient -7 2)").should eq("-3")
  end

  it "quotient raises on zero divisor" do
    expect_raises(Scheme::SchemeRuntimeError, /quotient: division by zero/) { w("(quotient 1 0)") }
  end

  it "abs handles ints and floats" do
    w("(abs -5)").should eq("5")
    w("(abs -5.5)").should eq("5.5")
  end

  it "abs raises for a non-number" do
    expect_raises(Scheme::SchemeRuntimeError, /abs: expected number/) { w(%((abs "x"))) }
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

  it "gcd computes the greatest common divisor" do
    w("(gcd 12 18)").should eq("6")
  end

  it "gcd of no arguments is 0" do
    w("(gcd)").should eq("0")
  end

  it "gcd is always non-negative regardless of operand signs" do
    w("(gcd -12 18)").should eq("6")
  end

  it "lcm computes the least common multiple" do
    w("(lcm 4 6)").should eq("12")
  end

  it "lcm of no arguments is 1" do
    w("(lcm)").should eq("1")
  end

  it "expt computes integer powers" do
    w("(expt 2 10)").should eq("1024")
  end

  it "expt computes exact rationals for negative integer exponents" do
    w("(expt 2 -1)").should eq("1/2")
    w("(expt 3 -2)").should eq("1/9")
  end

  it "expt computes float powers for a float base or exponent" do
    w("(expt 2.0 3)").should eq("8.0")
  end

  it "sqrt computes an exact result for a perfect square" do
    w("(import (scheme inexact)) (sqrt 16)").should eq("4")
    w("(import (scheme inexact)) (sqrt 0)").should eq("0")
  end

  it "sqrt computes a float square root for a non-perfect-square" do
    w("(import (scheme inexact)) (sqrt 2)").should eq("1.4142135623730951")
  end

  it "exact-integer-sqrt returns the floor root and remainder as two values" do
    w("(call-with-values (lambda () (exact-integer-sqrt 10)) list)").should eq("(3 1)")
    w("(call-with-values (lambda () (exact-integer-sqrt 9)) list)").should eq("(3 0)")
  end

  it "floor/ceiling/truncate/round return an exact integer unchanged" do
    w("(floor 3)").should eq("3")
    w("(ceiling 3)").should eq("3")
    w("(truncate 3)").should eq("3")
    w("(round 3)").should eq("3")
  end

  it "floor/ceiling/truncate/round on an inexact float stay inexact" do
    w("(floor 3.7)").should eq("3.0")
    w("(ceiling 3.2)").should eq("4.0")
    w("(truncate -3.7)").should eq("-3.0")
    w("(round 2.5)").should eq("2.0")
  end
end

describe "builtins: rational arithmetic" do
  it "adds two rationals, reducing the result" do
    w("(+ (/ 1 3) (/ 1 6))").should eq("1/2")
  end

  it "adding two rationals can collapse back to an exact integer" do
    w("(+ (/ 1 2) (/ 1 2))").should eq("1")
  end

  it "subtracts two rationals" do
    w("(- (/ 1 2) (/ 1 3))").should eq("1/6")
  end

  it "multiplies two rationals, reducing the result" do
    w("(* (/ 2 3) (/ 3 4))").should eq("1/2")
  end

  it "multiplying a rational by 0 collapses to exact 0" do
    w("(* (/ 1 2) 0)").should eq("0")
  end

  it "int + rational promotes to rational" do
    w("(+ 1 (/ 1 2))").should eq("3/2")
  end

  it "rational + float promotes to float (inexact contagion)" do
    w("(+ (/ 1 2) 1.0)").should eq("1.5")
  end

  it "rational - float promotes to float" do
    w("(- (/ 1 2) 0.5)").should eq("0.0")
  end

  it "rational * float promotes to float" do
    w("(* (/ 1 2) 2.0)").should eq("1.0")
  end

  it "dividing two rationals produces a reduced rational" do
    w("(/ (/ 1 2) (/ 1 4))").should eq("2")
  end

  it "int + int stays exact int (unchanged baseline behavior)" do
    w("(+ 1 2)").should eq("3")
  end

  it "int + float stays float (unchanged baseline behavior)" do
    w("(+ 1 2.0)").should eq("3.0")
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

  it "= compares rationals exactly" do
    w("(= (/ 1 2) (/ 2 4))").should eq("#t")
  end

  it "< compares rationals exactly, without a float round-trip" do
    w("(< (/ 1 3) (/ 1 2))").should eq("#t")
    w("(> (/ 1 2) (/ 1 3))").should eq("#t")
  end

  it "compares a rational against an int correctly" do
    w("(< (/ 1 2) 1)").should eq("#t")
    w("(> (/ 3 2) 1)").should eq("#t")
  end

  it "compares a rational against a float, using float contagion" do
    w("(= (/ 1 2) 0.5)").should eq("#t")
  end

  it "compares large exact integers precisely, without float rounding error" do
    w("(= 9007199254740993 9007199254740992)").should eq("#f")
    w("(< 9007199254740992 9007199254740993)").should eq("#t")
  end

  it "compares plain ints via the native fast path, not BigInt promotion" do
    w("(< 2000000000000 2000000000001)").should eq("#t")
    w("(= 2000000000000 2000000000000)").should eq("#t")
    w("(> -5 -6)").should eq("#t")
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
    expect_raises(Scheme::SchemeRuntimeError, /car: expected pair/) { w("(car 1)") }
  end

  it "cdr raises for a non-pair" do
    expect_raises(Scheme::SchemeRuntimeError, /cdr: expected pair/) { w("(cdr 1)") }
  end

  it "set-car!/set-cdr! mutate in place" do
    w("(define p (cons 1 2)) (set-car! p 9) (set-cdr! p 8) p").should eq("(9 . 8)")
  end

  it "set-car! raises for a non-pair" do
    expect_raises(Scheme::SchemeRuntimeError, /set-car!: expected pair/) { w("(set-car! 1 2)") }
  end

  it "set-cdr! raises for a non-pair" do
    expect_raises(Scheme::SchemeRuntimeError, /set-cdr!: expected pair/) { w("(set-cdr! 1 2)") }
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
    expect_raises(Scheme::SchemeRuntimeError, /list-ref: index 5 out of range/) { w("(list-ref '(a b c) 5)") }
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

  it "cons* conses leading args onto a possibly-improper tail" do
    w("(import (creme extra)) (cons* 1 2 3)").should eq("(1 2 . 3)")
    w("(import (creme extra)) (cons* 1 2 '(3 4))").should eq("(1 2 3 4)")
  end

  it "list-copy makes a shallow copy" do
    w("(define a '(1 2 3)) (define b (list-copy a)) (eq? a b)").should eq("#f")
    w("(list-copy '(1 2 3))").should eq("(1 2 3)")
  end

  it "list-set! mutates the element at an index" do
    w("(define l (list 1 2 3)) (list-set! l 1 99) l").should eq("(1 99 3)")
  end

  it "list-set! raises out of range" do
    expect_raises(Scheme::SchemeRuntimeError, /list-set!: index out of range/) { w("(list-set! (list 1 2) 5 9)") }
  end

  it "list-tail returns the sublist after dropping n elements" do
    w("(list-tail '(1 2 3 4 5) 2)").should eq("(3 4 5)")
    w("(list-tail '(1 2 3) 0)").should eq("(1 2 3)")
  end

  it "list-tail raises out of range" do
    expect_raises(Scheme::SchemeRuntimeError, /list-tail: index out of range/) { w("(list-tail '(1 2) 5)") }
  end

  it "make-list builds a list of n copies of a fill value" do
    w("(make-list 3 'x)").should eq("(x x x)")
  end

  it "make-list defaults to a list of length n" do
    w("(length (make-list 3))").should eq("3")
  end

  it "last-pair returns the final pair" do
    w("(import (creme extra)) (last-pair '(1 2 3))").should eq("(3)")
    w("(import (creme extra)) (last-pair (cons 1 2))").should eq("(1 . 2)")
  end

  it "assq/assv use identity comparison" do
    w("(assq 'b '((a . 1) (b . 2)))").should eq("(b . 2)")
    w("(assv 2 '((1 . a) (2 . b)))").should eq("(2 . b)")
    w(%((assq "a" '(("a" . 1))))).should eq("#f")
  end

  it "assoc uses equal? by default" do
    w(%((assoc "b" '(("a" . 1) ("b" . 2))))).should eq(%(("b" . 2)))
  end

  it "assoc accepts an optional comparator" do
    w("(assoc 2 '((1 . a) (10 . b)) (lambda (x y) (< (abs (- x y)) 3)))").should eq("(1 . a)")
  end

  it "assq/assv/assoc return #f when nothing matches" do
    w("(assq 'z '((a . 1)))").should eq("#f")
  end

  it "memq/memv use identity comparison" do
    w("(memq 'b '(a b c))").should eq("(b c)")
    w("(memv 2 '(1 2 3))").should eq("(2 3)")
  end

  it "member uses equal? by default" do
    w(%((member "b" '("a" "b" "c")))).should eq(%(("b" "c")))
  end

  it "member accepts an optional comparator" do
    w("(member 4 '(1 5 10) (lambda (x y) (< (abs (- x y)) 2)))").should eq("(5 10)")
  end

  it "memq/memv/member return #f when nothing matches" do
    w("(memq 'z '(a b c))").should eq("#f")
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
    w("(import (creme extra)) (filter (lambda (x) (> x 2)) '(1 2 3 4))").should eq("(3 4)")
  end

  it "reduce folds from the left with a seed" do
    w("(import (creme extra)) (reduce + 0 '(1 2 3 4 5))").should eq("15")
  end

  it "foldl folds left to right" do
    w("(import (creme extra)) (foldl cons '() '(1 2 3))").should eq("(((() . 1) . 2) . 3)")
  end

  it "foldr folds right to left" do
    w("(import (creme extra)) (foldr cons '() '(1 2 3))").should eq("(1 2 3)")
  end

  it "for-each evaluates for side effects and returns nil" do
    w("(define sum 0) (for-each (lambda (x) (set! sum (+ sum x))) '(1 2 3)) sum").should eq("6")
  end

  it "apply spreads a trailing list of args" do
    w("(apply + 1 2 '(3 4))").should eq("10")
  end
end

describe "builtins: SRFI-1 convenience" do
  it "iota defaults to a 0-based, step-1 list of the given count" do
    w("(import (creme extra)) (iota 5)").should eq("(0 1 2 3 4)")
  end

  it "iota accepts an explicit start and step" do
    w("(import (creme extra)) (iota 5 10)").should eq("(10 11 12 13 14)")
    w("(import (creme extra)) (iota 5 0 2)").should eq("(0 2 4 6 8)")
  end

  it "iota with count 0 returns the empty list" do
    w("(import (creme extra)) (iota 0)").should eq("()")
  end

  it "any returns the first truthy result, or #f if none match" do
    w("(import (creme extra)) (any odd? '(2 4 5 6))").should eq("#t")
    w("(import (creme extra)) (any odd? '(2 4 6))").should eq("#f")
  end

  it "every returns the last result if all match, or #f otherwise" do
    w("(import (creme extra)) (every odd? '(1 3 5))").should eq("#t")
    w("(import (creme extra)) (every odd? '(1 3 4))").should eq("#f")
  end

  it "count counts how many elements satisfy the predicate" do
    w("(import (creme extra)) (count odd? '(1 2 3 4 5))").should eq("3")
  end

  it "partition returns two values: matching then non-matching" do
    w("(import (creme extra)) (call-with-values (lambda () (partition odd? '(1 2 3 4 5))) list)").should eq("((1 3 5) (2 4))")
  end

  it "filter-map maps then drops falsy results" do
    w("(import (creme extra)) (filter-map (lambda (x) (and (odd? x) (* x x))) '(1 2 3 4 5))").should eq("(1 9 25)")
  end

  it "append-map maps then flattens the results" do
    w("(import (creme extra)) (append-map (lambda (x) (list x x)) '(1 2 3))").should eq("(1 1 2 2 3 3)")
  end

  it "delete removes every element equal? to x" do
    w("(import (creme extra)) (delete 3 '(1 2 3 4 3 5))").should eq("(1 2 4 5)")
  end

  it "delete accepts an optional comparator" do
    w("(import (creme extra)) (delete 3 '(1 2 3 4 3 5) (lambda (x y) (= x y)))").should eq("(1 2 4 5)")
  end

  it "delete! behaves the same as delete" do
    w("(import (creme extra)) (delete! 3 '(1 2 3 4 3 5))").should eq("(1 2 4 5)")
  end
end

describe "builtins: values/call-with-values" do
  it "(values x) is transparent for a single value" do
    w("(values 1)").should eq("1")
    w("(+ 1 (values 2))").should eq("3")
  end

  it "call-with-values spreads multiple values as arguments to the consumer" do
    w("(call-with-values (lambda () (values 1 2 3)) +)").should eq("6")
    w("(call-with-values (lambda () (values 1 2)) list)").should eq("(1 2)")
  end

  it "call-with-values works when the producer returns a single ordinary value" do
    w("(call-with-values (lambda () 42) (lambda (x) (* x 2)))").should eq("84")
  end

  it "call-with-values works with zero values" do
    w("(call-with-values (lambda () (values)) list)").should eq("()")
  end
end

describe "builtins: symbols/booleans" do
  it "symbol=? compares symbols by name" do
    w("(symbol=? 'a 'a)").should eq("#t")
    w("(symbol=? 'a 'b)").should eq("#f")
    w("(symbol=? 'a 'a 'a)").should eq("#t")
  end

  it "boolean=? compares booleans by value" do
    w("(boolean=? #t #t)").should eq("#t")
    w("(boolean=? #t #f)").should eq("#f")
  end

  it "symbol=?/boolean=? raise for a non-matching argument type" do
    expect_raises(Scheme::SchemeRuntimeError, /symbol=\?: expected symbol/) { w("(symbol=? 'a 1)") }
    expect_raises(Scheme::SchemeRuntimeError, /boolean=\?: expected boolean/) { w("(boolean=? #t 1)") }
  end
end

describe "builtins: exactness conversions" do
  it "exact->inexact converts an exact rational to a float" do
    w("(import (creme extra)) (exact->inexact (/ 1 3))").should eq("0.3333333333333333")
  end

  it "exact->inexact on an already-inexact value is the identity" do
    w("(import (creme extra)) (exact->inexact 3.5)").should eq("3.5")
  end

  it "inexact->exact converts a terminating float to an exact rational" do
    w("(import (creme extra)) (inexact->exact 0.5)").should eq("1/2")
  end

  it "inexact->exact on an already-exact value is the identity" do
    w("(import (creme extra)) (inexact->exact 3)").should eq("3")
    w("(import (creme extra)) (inexact->exact (/ 1 3))").should eq("1/3")
  end

  it "exact/inexact are aliases for inexact->exact/exact->inexact" do
    w("(exact 0.25)").should eq("1/4")
    w("(inexact 3)").should eq("3.0")
  end

  it "inexact->exact raises for a float whose exact value is too large to represent" do
    expect_raises(Scheme::SchemeRuntimeError, /magnitude too large/) { w("(exact 1e300)") }
  end

  it "numerator/denominator on an exact integer" do
    w("(numerator 5)").should eq("5")
    w("(denominator 5)").should eq("1")
  end

  it "numerator/denominator on an exact rational" do
    w("(numerator (/ 3 4))").should eq("3")
    w("(denominator (/ 3 4))").should eq("4")
  end

  it "numerator/denominator on an inexact float round-trip through exact, staying inexact" do
    w("(numerator 2.5)").should eq("5.0")
    w("(denominator 2.5)").should eq("2.0")
  end
end

describe "builtins: type predicates" do
  it "number?/integer?/float?/real?" do
    w("(number? 1)").should eq("#t")
    w("(integer? 1)").should eq("#t")
    w("(import (creme extra)) (float? 1.0)").should eq("#t")
    w("(real? 1.0)").should eq("#t")
  end

  it "integer? is about numeric value, not representation: a whole-valued float is an integer" do
    w("(integer? 1.0)").should eq("#t")
    w("(integer? 1.5)").should eq("#f")
  end

  it "integer? is false for a non-integer rational (never true by construction)" do
    w("(integer? (/ 1 3))").should eq("#f")
  end

  it "rational? is true for exact numbers and finite floats" do
    w("(rational? 1)").should eq("#t")
    w("(rational? (/ 1 3))").should eq("#t")
    w("(rational? 1.5)").should eq("#t")
  end

  it "rational? is false for a non-finite float" do
    w("(import (scheme inexact)) (rational? (log 0))").should eq("#f")
  end

  it "exact-integer? is true only for SchemeInt" do
    w("(exact-integer? 5)").should eq("#t")
    w("(exact-integer? (/ 1 3))").should eq("#f")
    w("(exact-integer? 5.0)").should eq("#f")
  end

  it "exact?/inexact? classify by representation" do
    w("(exact? 5)").should eq("#t")
    w("(exact? (/ 1 3))").should eq("#t")
    w("(exact? 5.0)").should eq("#f")
    w("(inexact? 5.0)").should eq("#t")
    w("(inexact? 5)").should eq("#f")
  end

  it "nan?/infinite?/finite? on finite values" do
    w("(import (scheme inexact)) (nan? 1.0)").should eq("#f")
    w("(import (scheme inexact)) (infinite? 1.0)").should eq("#f")
    w("(import (scheme inexact)) (finite? 1.0)").should eq("#t")
    w("(import (scheme inexact)) (finite? 1)").should eq("#t")
  end

  it "nan?/infinite?/finite? on a non-finite float (via a real math builtin, since / by float 0 still raises)" do
    w("(import (scheme inexact)) (infinite? (log 0))").should eq("#t")
    w("(import (scheme inexact)) (finite? (log 0))").should eq("#f")
    w("(import (scheme inexact)) (nan? (log -1))").should eq("#t")
    w("(import (scheme inexact)) (nan? (log 0))").should eq("#f")
  end

  it "square computes n * n, preserving exactness" do
    w("(square 5)").should eq("25")
    w("(square (/ 1 3))").should eq("1/9")
    w("(square 2.0)").should eq("4.0")
  end

  it "even?/odd?/zero?/positive?/negative? work across the numeric tower" do
    w("(even? 4)").should eq("#t")
    w("(odd? 3)").should eq("#t")
    w("(even? 4.0)").should eq("#t")
    w("(zero? (/ 0 5))").should eq("#t")
    w("(positive? (/ 1 2))").should eq("#t")
    w("(negative? (/ -1 2))").should eq("#t")
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
    w("(import (creme introspection)) (defmacro m (x) x) (macro? m)").should eq("#t")
    w("(import (creme introspection)) (macro? car)").should eq("#f")
  end
end

describe "builtins: macros" do
  it "gensym returns a fresh symbol each call" do
    w("(import (creme introspection)) (symbol? (gensym))").should eq("#t")
    w("(import (creme introspection)) (eq? (gensym) (gensym))").should eq("#f")
  end

  it "gensym honors an optional prefix" do
    w(%((import (creme introspection)) (symbol->string (gensym "tmp")))).should match(/^"tmp__\d+"$/)
  end

  it "gensym defaults to a \"g\" prefix" do
    w("(import (creme introspection)) (symbol->string (gensym))").should match(/^"g__\d+"$/)
  end
end

describe "builtins: characters" do
  it "char-upcase/char-downcase" do
    w("(import (scheme char)) (char-upcase #\\a)").should eq("#\\A")
    w("(import (scheme char)) (char-downcase #\\A)").should eq("#\\a")
  end

  it "char-alphabetic?/char-numeric?/char-whitespace?" do
    w("(import (scheme char)) (char-alphabetic? #\\a)").should eq("#t")
    w("(import (scheme char)) (char-alphabetic? #\\1)").should eq("#f")
    w("(import (scheme char)) (char-numeric? #\\5)").should eq("#t")
    w("(import (scheme char)) (char-numeric? #\\a)").should eq("#f")
    w("(import (scheme char)) (char-whitespace? #\\space)").should eq("#t")
    w("(import (scheme char)) (char-whitespace? #\\a)").should eq("#f")
  end

  it "char-upper-case?/char-lower-case?" do
    w("(import (scheme char)) (char-upper-case? #\\A)").should eq("#t")
    w("(import (scheme char)) (char-upper-case? #\\a)").should eq("#f")
    w("(import (scheme char)) (char-lower-case? #\\a)").should eq("#t")
    w("(import (scheme char)) (char-lower-case? #\\A)").should eq("#f")
  end

  it "char comparison procedures chain" do
    w("(char=? #\\a #\\a #\\a)").should eq("#t")
    w("(char<? #\\a #\\b #\\c)").should eq("#t")
    w("(char<? #\\a #\\c #\\b)").should eq("#f")
    w("(char>? #\\c #\\b #\\a)").should eq("#t")
    w("(char<=? #\\a #\\a #\\b)").should eq("#t")
    w("(char>=? #\\b #\\b #\\a)").should eq("#t")
  end

  it "char-ci comparison procedures ignore case" do
    w("(import (scheme char)) (char-ci=? #\\A #\\a)").should eq("#t")
    w("(char=? #\\A #\\a)").should eq("#f")
    w("(import (scheme char)) (char-ci<? #\\A #\\b)").should eq("#t")
  end

  it "char procedures raise for a non-char argument" do
    expect_raises(Scheme::SchemeRuntimeError, /char-upcase: expected char/) { w("(import (scheme char)) (char-upcase 5)") }
  end
end

describe "builtins: strings" do
  it "string-append concatenates" do
    w(%((string-append "a" "b" "c"))).should eq(%("abc"))
  end

  it "string-append raises for a non-string" do
    expect_raises(Scheme::SchemeRuntimeError, /string-append: expected string/) { w(%((string-append "a" 1))) }
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
    expect_raises(Scheme::SchemeRuntimeError, /substring: index out of range/) { w(%((substring "hi" 0 5))) }
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

  it "number->string with a radix" do
    w("(number->string 255 16)").should eq(%("ff"))
    w("(number->string 255 2)").should eq(%("11111111"))
    w("(number->string 8 8)").should eq(%("10"))
  end

  it "number->string with radix 10 explicit is the same as no radix" do
    w("(number->string 42 10)").should eq(%("42"))
  end

  it "number->string raises for a non-10 radix on an inexact/non-integer number" do
    expect_raises(Scheme::SchemeRuntimeError, /requires an exact integer/) { w("(number->string 4.5 16)") }
  end

  it "number->string raises for an unsupported radix" do
    expect_raises(Scheme::SchemeRuntimeError, /radix must be 2, 8, 10, or 16/) { w("(number->string 42 7)") }
  end

  it "string->number with a radix" do
    w(%((string->number "ff" 16))).should eq("255")
    w(%((string->number "1010" 2))).should eq("10")
    w(%((string->number "10" 8))).should eq("8")
  end

  it "string->number with a radix returns #f for unparsable text" do
    w(%((string->number "zz" 16))).should eq("#f")
  end

  it "string=? compares multiple strings" do
    w(%((string=? "a" "a" "a"))).should eq("#t")
    w(%((string=? "a" "a" "b"))).should eq("#f")
  end

  it "string<?/string>?/string<=?/string>=? compare lexicographically" do
    w(%((string<? "a" "b" "c"))).should eq("#t")
    w(%((string<? "a" "c" "b"))).should eq("#f")
    w(%((string>? "c" "b" "a"))).should eq("#t")
    w(%((string<=? "a" "a" "b"))).should eq("#t")
    w(%((string>=? "b" "a" "a"))).should eq("#t")
  end

  it "string-ref indexes a character" do
    w(%((string-ref "hello" 1))).should eq(%(#\\e))
    expect_raises(Scheme::SchemeRuntimeError, /string-ref: index out of range/) { w(%((string-ref "hi" 5))) }
  end

  it "string->list and list->string round-trip" do
    w(%((string->list "ab"))).should eq(%((#\\a #\\b)))
    w(%((list->string (list #\\a #\\b)))).should eq(%("ab"))
  end

  it "make-string fills with a char, defaulting to space" do
    w(%((make-string 3 #\\z))).should eq(%("zzz"))
    w(%((make-string 2))).should eq(%("  "))
  end

  it "char->integer and integer->char convert code points" do
    w(%((char->integer #\\A))).should eq("65")
    w(%((integer->char 97))).should eq(%(#\\a))
  end

  it "string->list accepts an optional start/end range" do
    w(%((string->list "hello" 1 3))).should eq(%((#\\e #\\l)))
  end

  it "string-map applies a function across one or more strings" do
    w(%((import (scheme char)) (string-map char-upcase "hello"))).should eq(%("HELLO"))
  end

  it "string-map supports multiple strings, stopping at the shortest" do
    w("(string-map (lambda (a b) (if (char=? a b) #\\= #\\!)) \"abc\" \"abd\")").should eq(%("==!"))
  end

  it "string-for-each calls a function for its side effect, returning nil" do
    w(%((let ((out '())) (string-for-each (lambda (c) (set! out (cons c out))) "ab") (reverse out)))).should eq(%((#\\a #\\b)))
  end

  it "string-copy copies a whole string or a range" do
    w(%((string-copy "hello"))).should eq(%("hello"))
    w(%((string-copy "hello" 1 3))).should eq(%("el"))
  end

  it "string-copy! overwrites a range of the destination string" do
    w(%((define s (make-string 5 #\\x)) (string-copy! s 1 "AB") s)).should eq(%("xABxx"))
  end

  it "string-copy! raises when the destination range is out of bounds" do
    expect_raises(Scheme::SchemeRuntimeError, /string-copy!: destination range out of bounds/) do
      w(%((string-copy! (make-string 2) 1 "AB")))
    end
  end

  it "string-fill! overwrites a range with a char" do
    w(%((define s (make-string 5 #\\x)) (string-fill! s #\\z 1 3) s)).should eq(%("xzzxx"))
  end

  it "string-fill! with no range fills the whole string" do
    w(%((define s (make-string 3 #\\x)) (string-fill! s #\\z) s)).should eq(%("zzz"))
  end

  it "string->vector and vector->string round-trip" do
    w(%((string->vector "abc"))).should eq(%(#(#\\a #\\b #\\c)))
    w("(vector->string (vector #\\a #\\b #\\c))").should eq(%("abc"))
  end
end

describe "builtins: I/O" do
  it "display/write/newline/print/println return nil" do
    w("(display 1)").should eq("()")
    w("(write 1)").should eq("()")
    w("(newline)").should eq("()")
    w("(import (creme extra)) (print 1)").should eq("()")
    w("(import (creme extra)) (println 1)").should eq("()")
  end

  it "writes to the real STDOUT by default" do
    Scheme::Interpreter.new.stdout.should be(STDOUT)
  end

  it "captures display via a custom stdout" do
    io = IO::Memory.new
    interp = Scheme::Interpreter.new(stdout: io)
    Scheme.run_source(interp, %((display "hello")))
    io.to_s.should eq("hello")
  end

  it "captures write via a custom stdout" do
    io = IO::Memory.new
    interp = Scheme::Interpreter.new(stdout: io)
    Scheme.run_source(interp, %((write "hello")))
    io.to_s.should eq(%("hello"))
  end

  it "captures newline via a custom stdout" do
    io = IO::Memory.new
    interp = Scheme::Interpreter.new(stdout: io)
    Scheme.run_source(interp, "(newline)")
    io.to_s.should eq("\n")
  end

  it "captures print via a custom stdout, concatenated with no separator" do
    io = IO::Memory.new
    interp = Scheme::Interpreter.new(stdout: io, library_search_path: ["./modules"])
    Scheme.run_source(interp, "(import (creme extra)) (print 1 2)")
    io.to_s.should eq("12")
  end

  it "captures println via a custom stdout, with a trailing newline" do
    io = IO::Memory.new
    interp = Scheme::Interpreter.new(stdout: io, library_search_path: ["./modules"])
    Scheme.run_source(interp, "(import (creme extra)) (println 1 2)")
    io.to_s.should eq("12\n")
  end

  it "accumulates output across multiple run_source calls against the same stdout" do
    io = IO::Memory.new
    interp = Scheme::Interpreter.new(stdout: io)
    Scheme.run_source(interp, %((display "a")))
    Scheme.run_source(interp, %((display "b")))
    io.to_s.should eq("ab")
  end
end

describe "builtins: ports" do
  it "current-output-port/current-input-port report port?/input-port?/output-port? correctly" do
    w("(port? (current-output-port))").should eq("#t")
    w("(output-port? (current-output-port))").should eq("#t")
    w("(input-port? (current-output-port))").should eq("#f")
    w("(input-port? (current-input-port))").should eq("#t")
    w("(output-port? (current-input-port))").should eq("#f")
  end

  it "display/write/newline/write-char/write-string accept an explicit output port" do
    io = IO::Memory.new
    interp = Scheme::Interpreter.new(stdout: io)
    Scheme.run_source(interp, %((display "z" (current-output-port))))
    io.to_s.should eq("z")
  end

  it "eof-object/eof-object? round-trip" do
    w("(eof-object? (eof-object))").should eq("#t")
    w("(eof-object? 1)").should eq("#f")
  end

  it "read-char/peek-char/read-line/read-string read from a custom stdin" do
    io = IO::Memory.new("ab\ncd")
    interp = Scheme::Interpreter.new(stdin: io)
    Scheme.run_source(interp, "(peek-char)").write_string.should eq(%(#\\a))
    Scheme.run_source(interp, "(read-char)").write_string.should eq(%(#\\a))
    Scheme.run_source(interp, "(read-line)").write_string.should eq(%("b"))
    Scheme.run_source(interp, "(read-string 2)").write_string.should eq(%("cd"))
    Scheme.run_source(interp, "(eof-object? (read-char))").write_string.should eq("#t")
  end

  it "current-error-port is an output port distinct from current-output-port" do
    w("(port? (current-error-port))").should eq("#t")
    w("(output-port? (current-error-port))").should eq("#t")
  end

  it "current-error-port writes route to the interpreter's stderr" do
    err = IO::Memory.new
    interp = Scheme::Interpreter.new(stderr: err)
    Scheme.run_source(interp, %((write-string "boom" (current-error-port))))
    err.to_s.should eq("boom")
  end

  it "flush-output-port defaults to the current output port and returns nil" do
    w("(flush-output-port)").should eq("()")
  end

  it "open-output-string/get-output-string round-trip" do
    w(%((define p (open-output-string)) (write 42 p) (write-string " x" p) (get-output-string p))).should eq(%("42 x"))
  end

  it "open-input-string/read parses one datum at a time, advancing the port" do
    src = "(import (scheme read)) (define p (open-input-string \"(1 2 3) foo \\\"bar\\\"\")) (list (read p) (read p) (read p))"
    w(src).should eq(%(((1 2 3) foo "bar")))
  end

  it "read returns the eof object once the port is exhausted" do
    w(%((import (scheme read)) (define p (open-input-string "1")) (read p) (eof-object? (read p)))).should eq("#t")
  end
end

describe "builtins: exit" do
  it "raises SchemeExit instead of terminating the process" do
    interp = Scheme::Interpreter.new
    expect_raises(Scheme::SchemeExit) do
      Scheme.run_source(interp, "(import (scheme process-context)) (exit)")
    end
  end

  it "defaults to code 0" do
    interp = Scheme::Interpreter.new
    ex = expect_raises(Scheme::SchemeExit) do
      Scheme.run_source(interp, "(import (scheme process-context)) (exit)")
    end
    ex.code.should eq(0)
  end

  it "clamps the given code to 0..255" do
    interp = Scheme::Interpreter.new
    ex = expect_raises(Scheme::SchemeExit) do
      Scheme.run_source(interp, "(import (scheme process-context)) (exit 300)")
    end
    ex.code.should eq(255)
  end
end

describe "builtins: misc" do
  it "error raises SchemeUserError with the joined message" do
    expect_raises(Scheme::SchemeUserError, /boom 1 2/) do
      w("(error \"boom\" 1 2)")
    end
  end

  it "error raises SchemeRuntimeError (superclass)" do
    expect_raises(Scheme::SchemeRuntimeError) do
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
    expect_raises(Scheme::SchemeRuntimeError, /make-vector: size must be non-negative/) do
      w("(make-vector -1)")
    end
  end

  it "vector-ref reads an element" do
    w("(vector-ref (vector 1 2 3) 1)").should eq("2")
  end

  it "vector-ref raises out of range" do
    expect_raises(Scheme::SchemeRuntimeError, /vector-ref: index 5 out of range/) do
      w("(vector-ref (vector 1 2 3) 5)")
    end
  end

  it "vector-set! mutates in place" do
    w("(define v (vector 1 2 3)) (vector-set! v 0 99) v").should eq("#(99 2 3)")
  end

  it "vector-set! raises out of range" do
    expect_raises(Scheme::SchemeRuntimeError, /vector-set!: index -1 out of range/) do
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

  it "vector->list accepts an optional start/end range" do
    w("(vector->list (vector 1 2 3 4) 1 3)").should eq("(2 3)")
  end

  it "vector-map applies a function across one or more vectors" do
    w("(vector-map (lambda (x) (* x x)) (vector 1 2 3))").should eq("#(1 4 9)")
    w("(vector-map + (vector 1 2 3) (vector 10 20 30))").should eq("#(11 22 33)")
  end

  it "vector-map stops at the shortest vector" do
    w("(vector-map + (vector 1 2 3) (vector 10 20))").should eq("#(11 22)")
  end

  it "vector-for-each calls a function for its side effect, returning nil" do
    w("(define sum 0) (vector-for-each (lambda (x) (set! sum (+ sum x))) (vector 1 2 3)) sum").should eq("6")
  end

  it "vector-copy copies a whole vector or a range" do
    w("(vector-copy (vector 1 2 3))").should eq("#(1 2 3)")
    w("(vector-copy (vector 1 2 3 4 5) 1 3)").should eq("#(2 3)")
  end

  it "vector-copy! overwrites a range of the destination vector" do
    w("(define v (vector 0 0 0 0 0)) (vector-copy! v 1 (vector 9 9)) v").should eq("#(0 9 9 0 0)")
  end

  it "vector-copy! raises when the destination range is out of bounds" do
    expect_raises(Scheme::SchemeRuntimeError, /vector-copy!: destination range out of bounds/) do
      w("(vector-copy! (make-vector 2) 1 (vector 9 9))")
    end
  end

  it "vector-fill! overwrites a range with a value" do
    w("(define v (vector 0 0 0 0 0)) (vector-fill! v 'x 1 3) v").should eq("#(0 x x 0 0)")
  end

  it "vector-fill! with no range fills the whole vector" do
    w("(define v (vector 0 0 0)) (vector-fill! v 'x) v").should eq("#(x x x)")
  end

  it "vector-append concatenates vectors" do
    w("(vector-append (vector 1 2) (vector 3 4) (vector 5))").should eq("#(1 2 3 4 5)")
  end

  it "vector-append with no args returns an empty vector" do
    w("(vector-append)").should eq("#()")
  end
end

describe "builtins: eval" do
  it "evaluates a quoted form" do
    w("(import (scheme eval)) (eval '(+ 1 2))").should eq("3")
  end

  it "evaluates a quasiquoted form built from data" do
    w("(import (scheme eval)) (eval (list '+ 1 2))").should eq("3")
  end

  it "sees definitions made by earlier eval calls" do
    w("(import (scheme eval)) (eval '(define x 10)) (eval 'x)").should eq("10")
  end

  it "propagates errors like a normal call" do
    expect_raises(Scheme::SchemeRuntimeError, /car:/) { w("(import (scheme eval)) (eval '(car 1))") }
  end
end

describe "current-output-port as a real parameter (eval-string's portable replacement)" do
  # eval-string used to swap @stdout at the Crystal level for the duration
  # of a call so evaluated code's own display/print couldn't reach the
  # real terminal. Now that current-output-port is a genuine R7RS
  # parameter object, the same "capture whatever this evaluates prints"
  # pattern is expressible in portable Scheme: parameterize it to a
  # string port, eval, then read back get-output-string.
  it "parameterize redirects display's default target to a string port" do
    w(<<-SCHEME).should eq(%("hi 2"))
      (import (scheme eval))
      (define p (open-output-string))
      (parameterize ((current-output-port p))
        (display "hi ")
        (display (eval '(+ 1 1))))
      (get-output-string p)
      SCHEME
  end

  it "restores the previous current-output-port after the dynamic extent ends" do
    w(<<-SCHEME).should eq(%("before-after"))
      (define p (open-output-string))
      (define out (open-output-string))
      (parameterize ((current-output-port p)) (display "captured"))
      (display "before-" out)
      (display "after" out)
      (get-output-string out)
      SCHEME
  end

  it "restores current-output-port even if the parameterized body raises" do
    w(<<-SCHEME).should eq(%("real"))
      (define p (open-output-string))
      (define out (open-output-string))
      (guard (e (#t 'ignored))
        (parameterize ((current-output-port p)) (error "boom")))
      (display "real" out)
      (get-output-string out)
      SCHEME
  end

  it "interp.stdout= keeps working when no script has parameterized the port" do
    real_stdout = IO::Memory.new
    interp = Scheme::Interpreter.new(stdout: real_stdout)
    Scheme.run_source(interp, %((display "after")))
    real_stdout.to_s.should eq("after")
  end
end
