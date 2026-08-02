require "../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (scheme base) (creme set) (creme sort)) #{src}").write_string
end

describe "set module" do
  it "builds a set from variadic items and lists it back" do
    w("(set-size (set 1 2 3))").should eq("3")
  end

  it "collapses duplicate members" do
    w("(set-size (set 1 1 2))").should eq("2")
  end

  it "reports membership" do
    w("(set-member? (set 1 2 3) 2)").should eq("#t")
    w("(set-member? (set 1 2 3) 9)").should eq("#f")
  end

  it "adds and deletes members in place" do
    w(<<-SCHEME).should eq("(#t #f)")
      (define s (set 1 2))
      (set-add! s 3)
      (define had-3 (set-member? s 3))
      (set-delete! s 3)
      (list had-3 (set-member? s 3))
      SCHEME
  end

  it "reports emptiness" do
    w("(set-empty? (make-set))").should eq("#t")
    w("(set-empty? (set 1))").should eq("#f")
  end

  it "copies independently of the original" do
    w(<<-SCHEME).should eq("(#t #f)")
      (define a (set 1 2))
      (define b (set-copy a))
      (set-add! b 3)
      (list (set-member? b 3) (set-member? a 3))
      SCHEME
  end

  it "clears all members in place" do
    w(<<-SCHEME).should eq("#t")
      (define s (set 1 2 3))
      (set-clear! s)
      (set-empty? s)
      SCHEME
  end

  it "maps over members into a new set" do
    w("(set-size (set-map (set 1 2 3) (lambda (x) (* x 2))))").should eq("3")
  end

  it "collapses map results that collide" do
    w("(set-size (set-map (set 1 2 3) (lambda (x) 0)))").should eq("1")
  end

  it "filters members into a new set" do
    w("(list-sort < (set->list (set-filter (set 1 2 3 4) even?)))").should eq("(2 4)")
  end

  it "computes union" do
    w("(list-sort < (set->list (set-union (set 1 2) (set 2 3))))").should eq("(1 2 3)")
  end

  it "computes intersection" do
    w("(list-sort < (set->list (set-intersection (set 1 2 3) (set 2 3 4))))").should eq("(2 3)")
  end

  it "computes difference" do
    w("(list-sort < (set->list (set-difference (set 1 2 3) (set 2 3 4))))").should eq("(1)")
  end

  it "computes symmetric difference" do
    w("(list-sort < (set->list (set-symmetric-difference (set 1 2 3) (set 2 3 4))))").should eq("(1 4)")
  end

  it "checks subset/superset" do
    w("(set-subset? (set 1 2) (set 1 2 3))").should eq("#t")
    w("(set-subset? (set 1 9) (set 1 2 3))").should eq("#f")
    w("(set-superset? (set 1 2 3) (set 1 2))").should eq("#t")
  end

  it "checks disjointness" do
    w("(set-disjoint? (set 1 2) (set 3 4))").should eq("#t")
    w("(set-disjoint? (set 1 2) (set 2 3))").should eq("#f")
  end

  it "checks set equality regardless of insertion order" do
    w("(set-equal? (set 1 2 3) (set 3 2 1))").should eq("#t")
    w("(set-equal? (set 1 2) (set 1 2 3))").should eq("#f")
  end

  it "merges another set's members in place" do
    w("(list-sort < (set->list (set-merge! (set 1 2) (set 2 3))))").should eq("(1 2 3)")
  end

  it "distinguishes exact and inexact numbers, matching hash-table key semantics" do
    w("(set-size (set 1 1.0))").should eq("2")
  end

  describe "sorted-set" do
    it "always lists members in ascending order" do
      w("(sorted-set->list (sorted-set 3 1 2))").should eq("(1 2 3)")
    end

    it "supports a custom comparator" do
      w("(sorted-set->list (list->sorted-set (list 3 1 2) >))").should eq("(3 2 1)")
    end

    it "supports add!/delete!/member?/size" do
      w(<<-SCHEME).should eq("(#t #f 1)")
        (define s (make-sorted-set))
        (sorted-set-add! s 1)
        (sorted-set-add! s 2)
        (define has-1 (sorted-set-member? s 1))
        (sorted-set-delete! s 1)
        (define has-1-after (sorted-set-member? s 1))
        (list has-1 has-1-after (sorted-set-size s))
        SCHEME
    end
  end
end
