require "../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (scheme base) (creme ostruct)) #{src}").write_string
end

describe "ostruct module" do
  it "builds from an alist and reads fields back" do
    w("(ostruct-ref (make-ostruct (list (cons 'name \"Alice\") (cons 'age 30))) 'age)").should eq("30")
  end

  it "returns #f for an unset field with no default" do
    w("(ostruct-ref (make-ostruct '()) 'missing)").should eq("#f")
  end

  it "returns the given default for an unset field" do
    w("(ostruct-ref (make-ostruct '()) 'missing 42)").should eq("42")
  end

  it "uses a procedure default verbatim, without calling it" do
    w("(procedure? (ostruct-ref (make-ostruct '()) 'missing (lambda () 1)))").should eq("#t")
  end

  it "sets and overwrites fields in place" do
    w(<<-SCHEME).should eq("(1 2)")
      (define o (make-ostruct (list (cons 'x 1))))
      (define first (ostruct-ref o 'x))
      (ostruct-set! o 'x 2)
      (list first (ostruct-ref o 'x))
      SCHEME
  end

  it "deletes fields in place" do
    w(<<-SCHEME).should eq("(#t #f)")
      (define o (make-ostruct (list (cons 'x 1))))
      (define had (ostruct? o))
      (ostruct-delete! o 'x)
      (list had (ostruct-ref o 'x))
      SCHEME
  end

  it "recognizes ostruct? only for ostruct values" do
    w("(list (ostruct? (make-ostruct '())) (ostruct? 5))").should eq("(#t #f)")
  end

  it "builds via the ostruct macro from literal field clauses" do
    w("(ostruct-ref (ostruct (name \"Bob\") (age (+ 20 5))) 'age)").should eq("25")
  end

  it "iterates every field via ostruct-each" do
    w(<<-SCHEME).should eq("3")
      (define o (ostruct (a 1) (b 2)))
      (define total 0)
      (ostruct-each o (lambda (name value) (set! total (+ total value))))
      total
      SCHEME
  end

  it "round-trips to an alist" do
    w("(length (ostruct->alist (ostruct (a 1) (b 2))))").should eq("2")
  end
end
