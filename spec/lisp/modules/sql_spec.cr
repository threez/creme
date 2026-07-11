require "../../spec_helper"

private def w(src : String) : String
  interp = LISP::Interpreter.new
  LISP.run_source(interp, "(require 'sql) #{src}").write_string
end

private def run(src : String) : LISP::LispValue
  interp = LISP::Interpreter.new
  LISP.run_source(interp, "(require 'sql) #{src}")
end

describe "sql module" do
  it "opens an in-memory connection and recognizes it with connection?" do
    w(%((sql:connection? (sql:open ":memory:")))).should eq("#t")
    w(%((sql:connection? 42))).should eq("#f")
  end

  it "creates a table and reports rows-affected/last-insert-id" do
    w(<<-LISP).should eq(%((("rows-affected" . 0) ("last-insert-id" . 0))))
      (define conn (sql:open ":memory:"))
      (sql:execute conn "CREATE TABLE person (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")
      LISP
  end

  it "inserts rows with bound params and tracks last-insert-id" do
    w(<<-LISP).should eq(%((("rows-affected" . 1) ("last-insert-id" . 2))))
      (define conn (sql:open ":memory:"))
      (sql:execute conn "CREATE TABLE person (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")
      (sql:execute conn "INSERT INTO person (name, age) VALUES (?, ?)" "Alice" 30)
      (sql:execute conn "INSERT INTO person (name, age) VALUES (?, ?)" "Bob" 45)
      LISP
  end

  it "queries rows back as a vector of column alists" do
    w(<<-LISP).should eq(%(#((("id" . 1) ("name" . "Alice") ("age" . 30)) (("id" . 2) ("name" . "Bob") ("age" . 45)))))
      (define conn (sql:open ":memory:"))
      (sql:execute conn "CREATE TABLE person (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")
      (sql:execute conn "INSERT INTO person (name, age) VALUES (?, ?)" "Alice" 30)
      (sql:execute conn "INSERT INTO person (name, age) VALUES (?, ?)" "Bob" 45)
      (sql:query conn "SELECT id, name, age FROM person ORDER BY id")
      LISP
  end

  it "queries with bound params filtering rows" do
    w(<<-LISP).should eq(%(#((("name" . "Bob")))))
      (define conn (sql:open ":memory:"))
      (sql:execute conn "CREATE TABLE person (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")
      (sql:execute conn "INSERT INTO person (name, age) VALUES (?, ?)" "Alice" 30)
      (sql:execute conn "INSERT INTO person (name, age) VALUES (?, ?)" "Bob" 45)
      (sql:query conn "SELECT name FROM person WHERE age > ?" 40)
      LISP
  end

  it "round-trips float and null column values" do
    w(<<-LISP).should eq("(#t #t)")
      (define conn (sql:open ":memory:"))
      (define row (vector-ref (sql:query conn "SELECT 1.5 AS a, NULL AS b") 0))
      (list (= 1.5 (cdr (assoc "a" row))) (null? (cdr (assoc "b" row))))
      LISP
  end

  it "returns a scalar value" do
    w(<<-LISP).should eq("2")
      (define conn (sql:open ":memory:"))
      (sql:execute conn "CREATE TABLE person (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")
      (sql:execute conn "INSERT INTO person (name, age) VALUES (?, ?)" "Alice" 30)
      (sql:execute conn "INSERT INTO person (name, age) VALUES (?, ?)" "Bob" 45)
      (sql:scalar conn "SELECT COUNT(*) FROM person")
      LISP
  end

  it "closes a connection without raising" do
    w(%((begin (sql:close (sql:open ":memory:")) "ok"))).should eq(%("ok"))
  end

  it "raises a LispRuntimeError on invalid sql" do
    expect_raises(LISP::LispRuntimeError, /sql:execute:/) do
      run(%((sql:execute (sql:open ":memory:") "NOT VALID SQL")))
    end
  end

  it "raises a LispRuntimeError on scalar with no rows" do
    expect_raises(LISP::LispRuntimeError, /sql:scalar:/) do
      run(<<-LISP)
        (define conn (sql:open ":memory:"))
        (sql:execute conn "CREATE TABLE person (id INTEGER PRIMARY KEY)")
        (sql:scalar conn "SELECT id FROM person WHERE id = 999")
        LISP
    end
  end
end
