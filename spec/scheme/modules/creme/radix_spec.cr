require "../../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (creme radix)) #{src}").write_string
end

describe "radix module" do
  describe "construction/basics" do
    it "recognizes radix-trees" do
      w("(radix-tree? (radix-tree))").should eq("#t")
      w("(radix-tree? 5)").should eq("#f")
    end

    it "starts empty" do
      w("(radix-tree-count (radix-tree))").should eq("0")
    end

    it "sets and refs a literal pattern" do
      w(<<-SCM).should eq("(greeting . 1)")
        (define t (radix-tree))
        (radix-tree-set! t "/hello" 'greeting)
        (cons (radix-tree-ref t "/hello") (radix-tree-count t))
      SCM
      w(%((radix-tree-ref (radix-tree) "/nope"))).should eq("#f")
    end

    it "overwrites without growing the count on re-registration" do
      w(<<-SCM).should eq("(second . 1)")
        (define t (radix-tree))
        (radix-tree-set! t "/hello" 'first)
        (radix-tree-set! t "/hello" 'second)
        (cons (radix-tree-ref t "/hello") (radix-tree-count t))
      SCM
    end
  end

  describe ":name capture" do
    it "captures a single named param via radix-tree-match" do
      w(<<-SCM).should eq(%[(user-by-id . "42")])
        (define t (radix-tree))
        (radix-tree-set! t "/users/:id" 'user-by-id)
        (define result (radix-tree-match t "/users/42"))
        (cons (car result) (cdr (assoc "id" (cdr result))))
      SCM
    end

    it "captures multiple named params in one path" do
      w(<<-SCM).should eq(%[("threez" . "creme")])
        (define t (radix-tree))
        (radix-tree-set! t "/orgs/:org/repos/:repo" 'repo-page)
        (define result (radix-tree-match t "/orgs/threez/repos/creme"))
        (cons (cdr (assoc "org" (cdr result))) (cdr (assoc "repo" (cdr result))))
      SCM
    end
  end

  describe "*name catch-all capture" do
    it "captures the entire remaining path" do
      w(<<-SCM).should eq(%("a/b/c.txt"))
        (define t (radix-tree))
        (radix-tree-set! t "/files/*path" 'file-catchall)
        (cdr (assoc "path" (cdr (radix-tree-match t "/files/a/b/c.txt"))))
      SCM
    end
  end

  describe "precedence" do
    it "a static route wins over an overlapping :name route regardless of registration order" do
      w(<<-SCM).should eq("(current-user . user-by-id)")
        (define t (radix-tree))
        (radix-tree-set! t "/users/:id" 'user-by-id)
        (radix-tree-set! t "/users/me" 'current-user)
        (cons (radix-tree-ref t "/users/me") (radix-tree-ref t "/users/42"))
      SCM
    end

    it "a :name route wins over an overlapping *name route regardless of registration order" do
      w(<<-SCM).should eq("(single-file . file-catchall)")
        (define t (radix-tree))
        (radix-tree-set! t "/files/*rest" 'file-catchall)
        (radix-tree-set! t "/files/:name" 'single-file)
        (cons (radix-tree-ref t "/files/report.pdf") (radix-tree-ref t "/files/a/b/c.txt"))
      SCM
    end
  end

  describe "unbounded depth/length" do
    it "matches a path deeper than the old 8-segment cap" do
      w(<<-SCM).should eq("deep-route")
        (define t (radix-tree))
        (define deep "/a/b/c/d/e/f/g/h/i/j/k/l")
        (radix-tree-set! t deep 'deep-route)
        (radix-tree-ref t deep)
      SCM
    end

    it "matches a segment longer than the old 64-byte cap" do
      w(<<-SCM).should eq("long-route")
        (define t (radix-tree))
        (define pattern (string-append "/" (make-string 200 #\\a)))
        (radix-tree-set! t pattern 'long-route)
        (radix-tree-ref t pattern)
      SCM
    end
  end

  describe "no match" do
    it "radix-tree-ref/radix-tree-match both return #f" do
      w(<<-SCM).should eq("(#f . #f)")
        (define t (radix-tree))
        (radix-tree-set! t "/hello" 'greeting)
        (cons (radix-tree-ref t "/goodbye") (radix-tree-match t "/goodbye"))
      SCM
    end
  end
end
