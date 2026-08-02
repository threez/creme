require "../../spec_helper"

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "R7RS §6.4 Pairs and lists" do
  it "pair? is #t for dotted and proper-list pairs, #f for the empty list and vectors" do
    w("(list (pair? '(a . b)) (pair? '(a b c)) (pair? '()) (pair? '#(a b)))").should eq("(#t #t #f #f)")
  end

  it "cons returns a newly allocated pair whose car/cdr are its two arguments" do
    w("(cons 'a '())").should eq("(a)")
    w("(cons '(a) '(b c d))").should eq("((a) b c d)")
    w("(cons 'a 3)").should eq("(a . 3)")
  end

  it "car/cdr access the pair's fields; it is an error to take car/cdr of the empty list" do
    w("(car '(a b c))").should eq("a")
    w("(cdr '((a) b c d))").should eq("(b c d)")
    expect_raises(Creme::SchemeRuntimeError) { run("(car '())") }
  end

  it "set-car!/set-cdr! mutate the pair's fields in place" do
    w("(define x (list 'a 'b)) (set-car! x 'z) x").should eq("(z b)")
  end

  it "caar/cadr/cdar/cddr are the depth-2 compositions of car and cdr" do
    w("(cadr '(a b c))").should eq("b")
    w("(caar '((a) b))").should eq("a")
  end

  it "null? is #t only for the empty list" do
    w("(list (null? '()) (null? '(a)) (null? 0))").should eq("(#t #f #f)")
  end

  it "list? is #t for every proper (finite, ()-terminated) list, #f for improper lists" do
    w("(list (list? '(a b c)) (list? '()) (list? '(a . b)))").should eq("(#t #t #f)")
  end

  it "list constructs a newly allocated list of its arguments" do
    w("(list 'a (+ 3 4) 'c)").should eq("(a 7 c)")
    w("(list)").should eq("()")
  end

  it "length returns a list's element count" do
    w("(length '(a b c))").should eq("3")
    w("(length '())").should eq("0")
  end

  it "append concatenates lists, sharing structure with (only) its last argument" do
    w("(append '(x) '(y))").should eq("(x y)")
    w("(append '(a) '(b c d))").should eq("(a b c d)")
    w("(append '(a b) '(c . d))").should eq("(a b c . d)")
    w("(append)").should eq("()")
    w("(append '() 'a)").should eq("a")
  end

  it "reverse returns a newly allocated list with elements in reverse order" do
    w("(reverse '(a b c))").should eq("(c b a)")
  end

  it "list-tail returns the sublist obtained by omitting the first k elements" do
    w("(list-tail '(a b c d) 2)").should eq("(c d)")
  end

  it "list-ref returns the kth element (0-indexed)" do
    w("(list-ref '(a b c d) 2)").should eq("c")
  end

  it "list-set! stores obj in element k of list" do
    w("(define ls (list 'one 'two 'five)) (list-set! ls 2 'three) ls").should eq("(one two three)")
  end

  it "memq/memv/member return the first sublist whose car matches obj (eq?/eqv?/equal? respectively)" do
    w("(memq 'a '(a b c))").should eq("(a b c)")
    w("(memq 'b '(a b c))").should eq("(b c)")
    w("(memq 'a '(b c d))").should eq("#f")
    w("(memv 101 '(100 101 102))").should eq("(101 102)")
  end

  it "member accepts an optional third comparison-predicate argument" do
    w(%[(import (scheme char)) (member "B" '("a" "b" "c") string-ci=?)]).should eq(%(("b" "c")))
  end

  it "assq/assv/assoc find the first pair in an alist whose car matches obj" do
    w("(define e '((a 1) (b 2) (c 3))) (assq 'a e)").should eq("(a 1)")
    w("(assq 'd '((a 1) (b 2) (c 3)))").should eq("#f")
    w("(assv 5 '((2 3) (5 7) (11 13)))").should eq("(5 7)")
  end

  it "assoc accepts an optional third comparison-predicate argument" do
    w("(assoc 2.0 (list (list 1 1) (list 2 4) (list 3 9)) =)").should eq("(2 4)")
  end

  it "list-copy returns a newly allocated shallow copy of a list" do
    w("(define a (list 1 8 2 8)) (define b (list-copy a)) (set-car! b 3) (list a b)").should eq("((1 8 2 8) (3 8 2 8))")
  end

  it "make-list returns a newly allocated list of k elements, optionally initialized to fill" do
    w("(make-list 2 3)").should eq("(3 3)")
  end
end
