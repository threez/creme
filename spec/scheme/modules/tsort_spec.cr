require "../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (creme tsort) (creme sort)) #{src}").write_string
end

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (creme tsort)) #{src}")
end

describe "tsort module" do
  it "sorts a simple dependency chain" do
    w("(tsort '((c . (b)) (b . (a)) (a . ())))").should eq("(a b c)")
  end

  it "includes leaf nodes only mentioned as a dependency" do
    w("(tsort '((b . (a))))").should eq("(a b)")
  end

  it "handles a diamond dependency graph, a before b/c before d" do
    w("(let* ((sorted (tsort '((d . (b c)) (b . (a)) (c . (a)) (a . ())))) (pos (lambda (x) (- (length sorted) (length (member x sorted)))))) (list (< (pos 'a) (pos 'b)) (< (pos 'a) (pos 'c)) (< (pos 'b) (pos 'd)) (< (pos 'c) (pos 'd))))")
      .should eq("(#t #t #t #t)")
  end

  it "handles independent nodes with no dependencies" do
    w("(list-sort (lambda (a b) (string<? (symbol->string a) (symbol->string b))) (tsort '((a . ()) (b . ()))))").should eq("(a b)")
  end

  it "raises on a cycle" do
    expect_raises(Creme::SchemeError) { run("(tsort '((a . (b)) (b . (a))))") }
  end

  it "tsort? reports #t for a DAG and #f for a cyclic graph" do
    w("(tsort? '((b . (a)) (a . ())))").should eq("#t")
    w("(tsort? '((a . (b)) (b . (a))))").should eq("#f")
  end

  describe "tsort-strongly-connected-components" do
    it "returns singleton components for a DAG, dependencies-first" do
      w("(tsort-strongly-connected-components '((c . (b)) (b . (a)) (a . ())))")
        .should eq("((a) (b) (c))")
    end

    it "collapses a cycle into one component" do
      w("(list-sort (lambda (a b) (string<? (symbol->string a) (symbol->string b))) (car (tsort-strongly-connected-components '((a . (b)) (b . (a))))))")
        .should eq("(a b)")
    end

    it "keeps an unrelated node as its own component" do
      w("(map (lambda (c) (list-sort (lambda (a b) (string<? (symbol->string a) (symbol->string b))) c)) (tsort-strongly-connected-components '((a . (b)) (b . (a)) (c . ()))))")
        .should eq("((a b) (c))")
    end
  end
end
