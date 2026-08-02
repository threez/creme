require "../../spec_helper"

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "R7RS §6.8 Vectors" do
  it "vector? is #t for vector objects, #f for lists" do
    w("(list (vector? #(1 2 3)) (vector? '(1 2)))").should eq("(#t #f)")
  end

  it "make-vector returns a newly allocated vector of k elements, optionally initialized to fill" do
    w("(make-vector 3 'a)").should eq("#(a a a)")
  end

  it "vector returns a newly allocated vector whose elements are its arguments" do
    w("(vector 'a 'b 'c)").should eq("#(a b c)")
  end

  it "vector-length returns the number of elements in the vector" do
    w("(vector-length (vector 1 2 3))").should eq("3")
  end

  it "vector-ref returns the contents of element k" do
    w("(vector-ref #(1 1 2 3 5 8 13 21) 5)").should eq("8")
  end

  it "vector-set! stores obj in element k of vector" do
    w(<<-SCM).should eq(%(#(0 ("Sue" "Sue") "Anna")))
      (define vec (vector 0 '(2 2 2) "Anna"))
      (vector-set! vec 1 '("Sue" "Sue"))
      vec
    SCM
  end

  it "vector->list/list->vector convert between a vector and a list, preserving order, with optional start" do
    w("(vector->list '#(dah dah didah) 1)").should eq("(dah didah)")
    w("(list->vector '(dididit dah))").should eq("#(dididit dah)")
  end

  it "vector->string/string->vector convert between a vector of characters and a string" do
    w("(vector->string #(#\\1 #\\2 #\\3))").should eq(%("123"))
    w(%[(string->vector "ABC")]).should eq("#(#\\A #\\B #\\C)")
  end

  it "vector-copy returns a newly allocated copy of the given range" do
    w("(define a (vector 1 8 2 8)) (define b (vector-copy a)) (vector-set! b 0 3) (list a b)").should eq("(#(1 8 2 8) #(3 8 2 8))")
  end

  it "vector-copy! copies a range of elements from one vector into another at a given offset" do
    w(<<-SCM).should eq("#(10 1 2 40 50)")
      (define a (vector 1 2 3 4 5))
      (define b (vector 10 20 30 40 50))
      (vector-copy! b 1 a 0 2)
      b
    SCM
  end

  it "vector-append returns a newly allocated concatenation of its vector arguments" do
    w("(vector-append #(a b c) #(d e f))").should eq("#(a b c d e f)")
  end

  it "vector-fill! stores fill in the elements of a vector between start and end" do
    w("(define a (vector 1 2 3 4 5)) (vector-fill! a 'smash 2 4) a").should eq("#(1 2 smash smash 5)")
  end

  it "vector-map applies a procedure element-wise across one or more vectors, returning a new vector" do
    w("(vector-map (lambda (n) (expt n n)) #(1 2 3 4 5))").should eq("#(1 4 27 256 3125)")
    w("(vector-map + #(1 2 3) #(4 5 6 7))").should eq("#(5 7 9)")
  end

  it "vector-for-each calls a procedure for its side effects over each element in order" do
    w(<<-SCM).should eq("#(0 1 4 9 16)")
      (define v (make-vector 5))
      (vector-for-each (lambda (i) (vector-set! v i (* i i))) #(0 1 2 3 4))
      v
    SCM
  end
end
