require "../../spec_helper"

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme sxql) (creme sql)) #{src}")
end

private def w(src : String) : String
  run(src).write_string
end

private def seed : String
  <<-SCHEME
    (define conn (sql-open ":memory:"))
    (sql-execute conn "CREATE TABLE books (title TEXT, author TEXT, year INTEGER)")
    (sql-execute conn "INSERT INTO books (title, author, year) VALUES (?, ?, ?)" "Practical Common Lisp" "Peter Seibel" 2005)
    (sql-execute conn "INSERT INTO books (title, author, year) VALUES (?, ?, ?)" "ANSI Common Lisp" "Paul Graham" 1995)
    (sql-execute conn "INSERT INTO books (title, author, year) VALUES (?, ?, ?)" "The Little Schemer" "Daniel Friedman" 1974)
    SCHEME
end

describe "sxql select! macro DSL" do
  it "executes a keyword-tree query against a real connection and returns keyword-alist rows" do
    w(<<-SCHEME).should eq(%((((:title . "Practical Common Lisp") (:author . "Peter Seibel") (:year . 2005)) ((:title . "ANSI Common Lisp") (:author . "Paul Graham") (:year . 1995)))))
      #{seed}
      (sxql-select! conn (:title :author :year)
        (from :books)
        (where (:and (:>= :year 1995)
                     (:< :year 2010)))
        (order-by (:desc :year)))
      SCHEME
  end

  it "accepts bare (non-keyword) symbols identically to keyword symbols" do
    w(<<-SCHEME).should eq(%((((:title . "The Little Schemer")))))
      #{seed}
      (sxql-select! conn (title)
        (from books)
        (where (< year 1995)))
      SCHEME
  end

  it "supports a literal value list for :in / :not-in" do
    w(<<-SCHEME).should eq(%((((:title . "Practical Common Lisp")) ((:title . "The Little Schemer")))))
      #{seed}
      (sxql-select! conn (:title)
        (from :books)
        (where (:in :year (2005 1974)))
        (order-by (:desc :year)))
      SCHEME
  end

  it "returns an empty list when nothing matches" do
    w(<<-SCHEME).should eq("()")
      #{seed}
      (sxql-select! conn (:title)
        (from :books)
        (where (:> :year 3000)))
      SCHEME
  end
end
