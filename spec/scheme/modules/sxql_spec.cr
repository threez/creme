require "../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme sxql)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme sxql)) #{src}")
end

describe "sxql module" do
  it "builds a select with where/order-by/limit/offset" do
    w(<<-SCHEME).should eq(%(("SELECT id, name, age FROM person WHERE (age >= ? AND age < ?) ORDER BY age DESC LIMIT ? OFFSET ?" (18 65 10 5))))
      (sxql-yield (sxql-select '(id name age)
                    (sxql-from 'person)
                    (sxql-where (sxql-and (sxql->= 'age 18) (sxql-< 'age 65)))
                    (sxql-order-by (sxql-desc 'age))
                    (sxql-limit 10)
                    (sxql-offset 5)))
      SCHEME
  end

  it "AND-composes repeated where clauses" do
    w(<<-SCHEME).should eq(%(("SELECT x FROM t WHERE (a = ? AND b = ?)" (1 2))))
      (sxql-yield (sxql-select '(x) (sxql-from 't) (sxql-where (sxql-= 'a 1)) (sxql-where (sxql-= 'b 2))))
      SCHEME
  end

  it "renders distinct, group-by and having" do
    w(<<-SCHEME).should eq(%(("SELECT DISTINCT customer, SUM(amount) AS total FROM orders GROUP BY customer HAVING SUM(amount) > ?" (20))))
      (sxql-yield (sxql-select (list 'customer (sxql-as (sxql-raw "SUM(amount)") 'total))
                    (sxql-distinct)
                    (sxql-from 'orders)
                    (sxql-group-by 'customer)
                    (sxql-having (sxql-> (sxql-raw "SUM(amount)") 20))))
      SCHEME
  end

  it "renders inner and left joins" do
    w(<<-SCHEME).should eq(%(("SELECT a.x, b.y FROM a INNER JOIN b ON a.id = b.a_id" ())))
      (sxql-yield (sxql-select '(a.x b.y) (sxql-from 'a) (sxql-join 'b (sxql-= 'a.id 'b.a_id))))
      SCHEME

    w(<<-SCHEME).should eq(%(("SELECT a.x FROM a LEFT JOIN b ON a.id = b.a_id" ())))
      (sxql-yield (sxql-select '(a.x) (sxql-from 'a) (sxql-left-join 'b (sxql-= 'a.id 'b.a_id))))
      SCHEME
  end

  it "composes and/or/not/in/not-in/like/is-null/is-not-null" do
    w(<<-SCHEME).should eq(%(("SELECT x FROM t WHERE (status IN (?, ?) OR NOT (y IS NULL))" ("a" "b"))))
      (sxql-yield (sxql-select '(x) (sxql-from 't)
                    (sxql-where (sxql-or (sxql-in 'status (list "a" "b"))
                                          (sxql-not (sxql-is-null 'y))))))
      SCHEME

    w(<<-SCHEME).should eq(%(("SELECT x FROM t WHERE (id NOT IN (?, ?) AND y IS NOT NULL)" (1 2))))
      (sxql-yield (sxql-select '(x) (sxql-from 't)
                    (sxql-where (sxql-and (sxql-not-in 'id (list 1 2)) (sxql-is-not-null 'y)))))
      SCHEME

    w(<<-SCHEME).should eq(%(("SELECT x FROM t WHERE name LIKE ?" ("%foo%"))))
      (sxql-yield (sxql-select '(x) (sxql-from 't) (sxql-where (sxql-like 'name "%foo%"))))
      SCHEME
  end

  it "renders a case expression" do
    w(<<-SCHEME).should eq(%(("SELECT CASE WHEN age > ? THEN ? ELSE ? END AS category FROM person" (18 "adult" "minor"))))
      (sxql-yield (sxql-select (list (sxql-as (sxql-case (sxql-when (sxql-> 'age 18) "adult")
                                                          (sxql-else "minor"))
                                              'category))
                    (sxql-from 'person)))
      SCHEME
  end

  it "passes sxql-raw through verbatim" do
    w(%((sxql-yield (sxql-select (list (sxql-raw "COUNT(*)")) (sxql-from 'person))))).should eq(%(("SELECT COUNT(*) FROM person" ())))
  end

  it "builds insert-into with set=, on-conflict, and returning" do
    w(<<-SCHEME).should eq(%(("INSERT INTO person (name, age) VALUES (?, ?) RETURNING id" ("Alice" 30))))
      (sxql-yield (sxql-insert-into 'person (sxql-set= 'name "Alice" 'age 30) (sxql-returning 'id)))
      SCHEME

    w(<<-SCHEME).should eq(%(("INSERT INTO person (name) VALUES (?) ON CONFLICT (name) DO NOTHING" ("Alice"))))
      (sxql-yield (sxql-insert-into 'person (sxql-set= 'name "Alice") (sxql-on-conflict-do-nothing 'name)))
      SCHEME

    w(<<-SCHEME).should eq(%(("INSERT INTO person (name) VALUES (?) ON CONFLICT DO NOTHING" ("Alice"))))
      (sxql-yield (sxql-insert-into 'person (sxql-set= 'name "Alice") (sxql-on-conflict-do-nothing)))
      SCHEME

    w(<<-SCHEME).should eq(%(("INSERT INTO person (name) VALUES (?) ON CONFLICT (name) DO UPDATE SET name = ?" ("Alice" "Alice"))))
      (sxql-yield (sxql-insert-into 'person
                    (sxql-set= 'name "Alice")
                    (sxql-on-conflict-do-update (list 'name) (sxql-set= 'name "Alice"))))
      SCHEME
  end

  it "builds update with set= and where" do
    w(<<-SCHEME).should eq(%(("UPDATE person SET age = ? WHERE name = ?" (31 "Alice"))))
      (sxql-yield (sxql-update 'person (sxql-set= 'age 31) (sxql-where (sxql-= 'name "Alice"))))
      SCHEME
  end

  it "builds delete-from with where" do
    w(%((sxql-yield (sxql-delete-from 'person (sxql-where (sxql-= 'id 5)))))).should eq(%(("DELETE FROM person WHERE id = ?" (5))))
  end

  it "builds union and union-all" do
    w(<<-SCHEME).should eq(%(("SELECT x FROM a UNION SELECT x FROM b" ())))
      (sxql-yield (sxql-union (sxql-select '(x) (sxql-from 'a)) (sxql-select '(x) (sxql-from 'b))))
      SCHEME

    w(<<-SCHEME).should eq(%(("SELECT x FROM a UNION ALL SELECT x FROM b" ())))
      (sxql-yield (sxql-union-all (sxql-select '(x) (sxql-from 'a)) (sxql-select '(x) (sxql-from 'b))))
      SCHEME
  end

  it "builds create-table with column constraints" do
    w(<<-SCHEME).should eq(%(("CREATE TABLE IF NOT EXISTS person (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE, age INTEGER DEFAULT 0)" ())))
      (sxql-yield (sxql-create-table 'person
                    (list (sxql-column 'id "INTEGER" (sxql-primary-key) (sxql-autoincrement))
                          (sxql-column 'name "TEXT" (sxql-not-null) (sxql-unique))
                          (sxql-column 'age "INTEGER" (sxql-default 0)))
                    (sxql-if-not-exists)))
      SCHEME
  end

  it "renders a string DEFAULT literal with quote-escaping" do
    w(<<-SCHEME).should eq(%(("CREATE TABLE t (label TEXT DEFAULT 'it''s')" ())))
      (sxql-yield (sxql-create-table 't (list (sxql-column 'label "TEXT" (sxql-default "it's")))))
      SCHEME
  end

  it "builds drop-table with if-exists" do
    w(%((sxql-yield (sxql-drop-table 'person (sxql-if-exists))))).should eq(%(("DROP TABLE IF EXISTS person" ())))
  end

  it "builds all alter-table variants" do
    w(%((sxql-yield (sxql-alter-table 'person (sxql-rename-to 'people))))).should eq(%(("ALTER TABLE person RENAME TO people" ())))
    w(%((sxql-yield (sxql-alter-table 'person (sxql-add-column (sxql-column 'email "TEXT")))))).should eq(%(("ALTER TABLE person ADD COLUMN email TEXT" ())))
    w(%((sxql-yield (sxql-alter-table 'person (sxql-rename-column 'age 'years))))).should eq(%(("ALTER TABLE person RENAME COLUMN age TO years" ())))
    w(%((sxql-yield (sxql-alter-table 'person (sxql-drop-column 'age))))).should eq(%(("ALTER TABLE person DROP COLUMN age" ())))
  end

  it "builds create-index and drop-index" do
    w(<<-SCHEME).should eq(%(("CREATE UNIQUE INDEX IF NOT EXISTS idx_person_name ON person (name)" ())))
      (sxql-yield (sxql-create-index 'idx_person_name 'person (list 'name) (sxql-unique) (sxql-if-not-exists)))
      SCHEME

    w(%((sxql-yield (sxql-drop-index 'idx_person_name (sxql-if-exists))))).should eq(%(("DROP INDEX IF EXISTS idx_person_name" ())))
  end

  it "raises a SchemeRuntimeError on a malformed clause" do
    expect_raises(Scheme::SchemeRuntimeError, /sxql-select: expected a clause/) do
      run(%((sxql-select '(id) 42)))
    end
  end

  it "raises a SchemeRuntimeError when yielding a non-statement" do
    expect_raises(Scheme::SchemeRuntimeError, /sxql-yield: expected a built statement/) do
      run(%((sxql-yield 42)))
    end
  end

  it "raises a SchemeRuntimeError on odd set= arguments" do
    expect_raises(Scheme::SchemeRuntimeError, /sxql-set=: expected an even number/) do
      run(%((sxql-set= 'a 1 'b)))
    end
  end

  it "raises a SchemeRuntimeError on an unknown column constraint" do
    expect_raises(Scheme::SchemeRuntimeError, /sxql-column: unknown constraint/) do
      run(%((sxql-yield (sxql-create-table 'x (list (sxql-column 'id "INTEGER" (sxql-where 1)))))))
    end
  end
end
