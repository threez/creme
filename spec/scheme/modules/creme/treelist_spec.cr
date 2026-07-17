require "../../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, "(import (creme treelist)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, "(import (creme treelist)) #{src}")
end

describe "treelist module" do
  describe "construction and conversion" do
    it "builds and round-trips through lists" do
      w("(treelist->list (treelist 1 2 3))").should eq("(1 2 3)")
      w("(treelist->list (list->treelist '(a b c)))").should eq("(a b c)")
      w("(treelist->list empty-treelist)").should eq("()")
    end

    it "round-trips through vectors" do
      w("(treelist->vector (treelist 1 2 3))").should eq("#(1 2 3)")
      w("(treelist->list (vector->treelist #(4 5 6)))").should eq("(4 5 6)")
    end

    it "make-treelist fills with a value" do
      w("(treelist->list (make-treelist 3 'x))").should eq("(x x x)")
      w("(treelist->list (make-treelist 0 'x))").should eq("()")
    end

    it "has a write form" do
      w("(treelist 1 2 3)").should eq("#<treelist 1 2 3>")
      w("(treelist)").should eq("#<treelist>")
    end
  end

  describe "predicates and size" do
    it "recognizes treelists" do
      w("(treelist? (treelist 1))").should eq("#t")
      w("(treelist? '(1))").should eq("#f")
      w("(treelist? 5)").should eq("#f")
    end

    it "reports emptiness and length" do
      w("(treelist-empty? empty-treelist)").should eq("#t")
      w("(treelist-empty? (treelist 1))").should eq("#f")
      w("(treelist-length (treelist 1 2 3 4))").should eq("4")
    end
  end

  describe "access" do
    it "refs, firsts and lasts" do
      w("(treelist-ref (treelist 'a 'b 'c) 1)").should eq("b")
      w("(treelist-first (treelist 'a 'b 'c))").should eq("a")
      w("(treelist-last (treelist 'a 'b 'c))").should eq("c")
    end

    it "raises on out-of-range ref" do
      expect_raises(Scheme::SchemeRuntimeError, /out of range/) do
        run("(treelist-ref (treelist 1 2) 5)")
      end
    end

    it "raises on first/last of an empty treelist" do
      expect_raises(Scheme::SchemeRuntimeError, /empty treelist/) do
        run("(treelist-first empty-treelist)")
      end
    end
  end

  describe "functional update" do
    it "adds, conses and sets" do
      w("(treelist->list (treelist-add (treelist 1 2) 3))").should eq("(1 2 3)")
      w("(treelist->list (treelist-cons (treelist 2 3) 1))").should eq("(1 2 3)")
      w("(treelist->list (treelist-set (treelist 1 2 3) 1 'x))").should eq("(1 x 3)")
    end

    it "inserts and deletes" do
      w("(treelist->list (treelist-insert (treelist 1 2 4) 2 3))").should eq("(1 2 3 4)")
      w("(treelist->list (treelist-insert (treelist 2 3) 0 1))").should eq("(1 2 3)")
      w("(treelist->list (treelist-delete (treelist 1 2 3 4) 1))").should eq("(1 3 4)")
    end

    it "takes and drops from both ends" do
      w("(treelist->list (treelist-take (treelist 1 2 3 4 5) 2))").should eq("(1 2)")
      w("(treelist->list (treelist-drop (treelist 1 2 3 4 5) 2))").should eq("(3 4 5)")
      w("(treelist->list (treelist-take-right (treelist 1 2 3 4 5) 2))").should eq("(4 5)")
      w("(treelist->list (treelist-drop-right (treelist 1 2 3 4 5) 2))").should eq("(1 2 3)")
    end

    it "sublists, rests, appends and reverses" do
      w("(treelist->list (treelist-sublist (treelist 0 1 2 3 4) 1 4))").should eq("(1 2 3)")
      w("(treelist->list (treelist-rest (treelist 1 2 3)))").should eq("(2 3)")
      w("(treelist->list (treelist-append (treelist 1 2) (treelist 3) (treelist 4 5)))").should eq("(1 2 3 4 5)")
      w("(treelist->list (treelist-append))").should eq("()")
      w("(treelist->list (treelist-reverse (treelist 1 2 3)))").should eq("(3 2 1)")
    end

    it "raises on a bad insert position and take count" do
      expect_raises(Scheme::SchemeRuntimeError, /out of range/) do
        run("(treelist-insert (treelist 1 2) 9 'x)")
      end
      expect_raises(Scheme::SchemeRuntimeError, /out of range/) do
        run("(treelist-take (treelist 1 2) 9)")
      end
    end
  end

  describe "higher-order" do
    it "maps, filters, sorts and iterates" do
      w("(treelist->list (treelist-map (treelist 1 2 3) (lambda (x) (* x x))))").should eq("(1 4 9)")
      w("(treelist->list (treelist-filter odd? (treelist 1 2 3 4 5)))").should eq("(1 3 5)")
      w("(treelist->list (treelist-sort (treelist 3 1 2) <))").should eq("(1 2 3)")
    end

    it "for-each visits every element in order" do
      w("(let ((acc '())) (treelist-for-each (treelist 1 2 3) (lambda (x) (set! acc (cons x acc)))) acc)").should eq("(3 2 1)")
    end
  end

  describe "search" do
    it "finds members, indices and predicates" do
      w("(treelist-member? (treelist 'a 'b 'c) 'b)").should eq("#t")
      w("(treelist-member? (treelist 'a 'b 'c) 'z)").should eq("#f")
      w("(treelist-index-of (treelist 'a 'b 'c) 'c)").should eq("2")
      w("(treelist-index-of (treelist 'a 'b 'c) 'z)").should eq("#f")
      w("(treelist-find (treelist 1 2 3 4) even?)").should eq("2")
      w("(treelist-find (treelist 1 3 5) even?)").should eq("#f")
    end
  end

  describe "equality" do
    it "compares treelists element-wise" do
      w("(equal? (treelist 1 2 3) (treelist 1 2 3))").should eq("#t")
      w("(equal? (treelist 1 2 3) (treelist 1 2 4))").should eq("#f")
      w("(equal? (treelist 1 2) (treelist 1 2 3))").should eq("#f")
    end
  end

  describe "mutable treelists" do
    it "adds, conses and sets destructively" do
      w("(let ((m (mutable-treelist 1 2 3))) (mutable-treelist-add! m 4) (mutable-treelist-cons! m 0) (mutable-treelist->list m))").should eq("(0 1 2 3 4)")
      w("(let ((m (mutable-treelist 1 2 3))) (mutable-treelist-set! m 1 'x) (mutable-treelist->list m))").should eq("(1 x 3)")
    end

    it "recognizes and measures mutable treelists" do
      w("(mutable-treelist? (mutable-treelist 1))").should eq("#t")
      w("(mutable-treelist? (treelist 1))").should eq("#f")
      w("(mutable-treelist-length (mutable-treelist 1 2 3))").should eq("3")
    end

    it "inserts, deletes, appends and prepends" do
      w("(let ((m (mutable-treelist 1 2 4))) (mutable-treelist-insert! m 2 3) (mutable-treelist->list m))").should eq("(1 2 3 4)")
      w("(let ((m (mutable-treelist 1 2 3))) (mutable-treelist-delete! m 0) (mutable-treelist->list m))").should eq("(2 3)")
      w("(let ((m (mutable-treelist 1 2))) (mutable-treelist-append! m (treelist 3 4)) (mutable-treelist->list m))").should eq("(1 2 3 4)")
      w("(let ((m (mutable-treelist 3 4))) (mutable-treelist-prepend! m (treelist 1 2)) (mutable-treelist->list m))").should eq("(1 2 3 4)")
    end

    it "sorts, reverses and maps in place" do
      w("(let ((m (mutable-treelist 3 1 2))) (mutable-treelist-sort! m <) (mutable-treelist->list m))").should eq("(1 2 3)")
      w("(let ((m (mutable-treelist 1 2 3))) (mutable-treelist-reverse! m) (mutable-treelist->list m))").should eq("(3 2 1)")
      w("(let ((m (mutable-treelist 1 2 3))) (mutable-treelist-map! m (lambda (x) (+ x 10))) (mutable-treelist->list m))").should eq("(11 12 13)")
    end

    it "snapshots without aliasing later mutations" do
      w("(let* ((m (mutable-treelist 1 2 3)) (s (mutable-treelist-snapshot m))) (mutable-treelist-set! m 0 99) (list (treelist->list s) (mutable-treelist->list m)))").should eq("((1 2 3) (99 2 3))")
    end

    it "converts between mutable and immutable" do
      w("(mutable-treelist? (treelist-copy (treelist 1 2 3)))").should eq("#t")
      w("(treelist->list (mutable-treelist-snapshot (list->mutable-treelist '(1 2 3))))").should eq("(1 2 3)")
    end
  end

  describe "large treelists (multi-level trees and concat rebalancing)" do
    it "keeps ref correct across 5000 incremental adds" do
      run(<<-SCM).write_string.should eq("(0 2500 4999 5000)")
        (define big
          (let loop ((i 0) (t empty-treelist))
            (if (= i 5000) t (loop (+ i 1) (treelist-add t i)))))
        (list (treelist-ref big 0)
              (treelist-ref big 2500)
              (treelist-ref big 4999)
              (treelist-length big))
      SCM
    end

    it "concatenates two large treelists correctly" do
      run(<<-SCM).write_string.should eq("(6000 0 2999 0 2999)")
        (define a (list->treelist
                    (let loop ((i 0) (acc '()))
                      (if (= i 3000) (reverse acc) (loop (+ i 1) (cons i acc))))))
        (define c (treelist-append a a))
        (list (treelist-length c)
              (treelist-ref c 0)
              (treelist-ref c 2999)
              (treelist-ref c 3000)
              (treelist-ref c 5999))
      SCM
    end

    it "take/drop then append reconstructs a large treelist" do
      run(<<-SCM).write_string.should eq("#t")
        (define src (list->treelist
                      (let loop ((i 0) (acc '()))
                        (if (= i 2000) (reverse acc) (loop (+ i 1) (cons i acc))))))
        (equal? src (treelist-append (treelist-take src 777) (treelist-drop src 777)))
      SCM
    end
  end
end
