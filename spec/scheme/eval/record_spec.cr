require "../../spec_helper"

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "define-record-type" do
  it "defines a constructor, predicate, and accessors" do
    src = <<-SCHEME
      (define-record-type point
        (make-point x y)
        point?
        (x point-x)
        (y point-y))
      (define p (make-point 3 4))
      (list (point? p) (point-x p) (point-y p))
      SCHEME
    w(src).should eq("(#t 3 4)")
  end

  it "predicate is false for non-records and for records of a different type" do
    src = <<-SCHEME
      (define-record-type point (make-point x y) point? (x point-x) (y point-y))
      (define-record-type circle (make-circle r) circle? (r circle-r))
      (define p (make-point 1 2))
      (list (point? 5) (point? (make-circle 9)) (circle? p))
      SCHEME
    w(src).should eq("(#f #f #f)")
  end

  it "distinct define-record-type invocations produce disjoint types even with the same name" do
    src = <<-SCHEME
      (define (make-point-type)
        (define-record-type point (make-point x) point? (x point-x))
        (list make-point point?))
      (define a (make-point-type))
      (define b (make-point-type))
      (define make-a (car a))
      (define pred-b (car (cdr b)))
      (pred-b (make-a 1))
      SCHEME
    w(src).should eq("#f")
  end

  it "supports a mutator that mutates the field in place" do
    src = <<-SCHEME
      (define-record-type point (make-point x y) point? (x point-x) (y point-y set-point-y!))
      (define p (make-point 1 2))
      (set-point-y! p 99)
      (point-y p)
      SCHEME
    w(src).should eq("99")
  end

  it "a field with no mutator spec has no setter defined" do
    expect_raises(Scheme::SchemeRuntimeError, /unbound variable: set-point-x!/) do
      run("(define-record-type point (make-point x) point? (x point-x)) (set-point-x! (make-point 1) 2)")
    end
  end

  it "the constructor may take a subset of fields; unlisted fields default to nil" do
    src = <<-SCHEME
      (define-record-type point (make-point x) point? (x point-x) (y point-y))
      (point-y (make-point 1))
      SCHEME
    w(src).should eq("()")
  end

  it "accessor raises when called on the wrong type" do
    expect_raises(Scheme::SchemeRuntimeError, /point-x: expected a point record, got 5/) do
      run("(define-record-type point (make-point x) point? (x point-x)) (point-x 5)")
    end
  end

  it "the type name itself is bound to the record type descriptor" do
    w("(define-record-type point (make-point x) point? (x point-x)) point").should eq("#<record-type:point>")
  end

  it "displays a record instance with its type name and fields" do
    w("(define-record-type point (make-point x y) point? (x point-x) (y point-y)) (make-point 1 2)")
      .should eq("#<point x=1 y=2>")
  end

  it "raises on a malformed constructor field" do
    expect_raises(Scheme::SchemeRuntimeError, /define-record-type: constructor field '.*' is not a declared field/) do
      run("(define-record-type point (make-point x z) point? (x point-x) (y point-y))")
    end
  end

  it "raises on malformed input" do
    expect_raises(Scheme::SchemeRuntimeError, /define-record-type: malformed/) do
      run("(define-record-type point)")
    end
  end
end
