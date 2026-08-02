require "../../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (creme hash-table)) #{src}").write_string
end

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (creme hash-table)) #{src}")
end

describe "hash-table module" do
  it "make-hash-table/hash-table? construct an empty table" do
    w("(hash-table? (make-hash-table))").should eq("#t")
    w("(hash-table? 5)").should eq("#f")
  end

  it "hash-table-set!/hash-table-ref round-trip a value" do
    w("(define h (make-hash-table)) (hash-table-set! h 'a 1) (hash-table-ref h 'a)").should eq("1")
  end

  it "hash-table-set! overwrites an existing key" do
    w("(define h (make-hash-table)) (hash-table-set! h 'a 1) (hash-table-set! h 'a 2) (hash-table-ref h 'a)").should eq("2")
  end

  it "keys are compared by equal?, not identity" do
    src = "(define h (make-hash-table)) (hash-table-set! h (list 1 2) 'found) (hash-table-ref h (list 1 2) 'missing)"
    w(src).should eq("found")
  end

  it "string keys work via equal?" do
    src = %[(define h (make-hash-table)) (hash-table-set! h "k" 1) (hash-table-ref h "k")]
    w(src).should eq("1")
  end

  it "hash-table-ref raises when the key is missing and no default is given" do
    expect_raises(Creme::SchemeRuntimeError, /key not found/) do
      run("(define h (make-hash-table)) (hash-table-ref h 'missing)")
    end
  end

  it "hash-table-ref returns a plain default value when the key is missing" do
    w("(define h (make-hash-table)) (hash-table-ref h 'missing 'fallback)").should eq("fallback")
  end

  it "hash-table-ref calls a thunk default lazily when the key is missing" do
    src = "(define h (make-hash-table)) (hash-table-ref h 'missing (lambda () 'lazy))"
    w(src).should eq("lazy")
  end

  it "hash-table-delete! removes a key" do
    src = "(define h (make-hash-table)) (hash-table-set! h 'a 1) (hash-table-delete! h 'a) (hash-table-contains? h 'a)"
    w(src).should eq("#f")
  end

  it "hash-table-delete! on a missing key is a no-op" do
    w("(define h (make-hash-table)) (hash-table-delete! h 'missing)").should eq("()")
  end

  it "hash-table-contains? reports presence" do
    src = "(define h (make-hash-table)) (hash-table-set! h 'a 1) (list (hash-table-contains? h 'a) (hash-table-contains? h 'b))"
    w(src).should eq("(#t #f)")
  end

  it "hash-table-keys/hash-table-values/hash-table->alist" do
    src = "(define h (make-hash-table)) (hash-table-set! h 'a 1) (hash-table-set! h 'b 2)"
    w("#{src} (hash-table-keys h)").should eq("(a b)")
    w("#{src} (hash-table-values h)").should eq("(1 2)")
    w("#{src} (hash-table->alist h)").should eq("((a . 1) (b . 2))")
  end

  it "raises when given a non-hash-table" do
    expect_raises(Creme::SchemeRuntimeError, /hash-table-ref: expected a hash table/) do
      run("(hash-table-ref 5 'a)")
    end
  end
end
