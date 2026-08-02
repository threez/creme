require "../../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme sql)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme sql)) #{src}")
end

describe "sql module" do
  it "opens an in-memory connection and recognizes it with connection?" do
    w(%((sql-connection? (sql-open ":memory:")))).should eq("#t")
    w(%((sql-connection? 42))).should eq("#f")
  end

  it "creates a table and reports rows-affected/last-insert-id" do
    w(<<-SCHEME).should eq(%((("rows-affected" . 0) ("last-insert-id" . 0))))
      (define conn (sql-open ":memory:"))
      (sql-execute conn "CREATE TABLE person (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")
      SCHEME
  end

  it "inserts rows with bound params and tracks last-insert-id" do
    w(<<-SCHEME).should eq(%((("rows-affected" . 1) ("last-insert-id" . 2))))
      (define conn (sql-open ":memory:"))
      (sql-execute conn "CREATE TABLE person (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")
      (sql-execute conn "INSERT INTO person (name, age) VALUES (?, ?)" "Alice" 30)
      (sql-execute conn "INSERT INTO person (name, age) VALUES (?, ?)" "Bob" 45)
      SCHEME
  end

  it "queries rows back as a vector of column alists" do
    w(<<-SCHEME).should eq(%(#((("id" . 1) ("name" . "Alice") ("age" . 30)) (("id" . 2) ("name" . "Bob") ("age" . 45)))))
      (define conn (sql-open ":memory:"))
      (sql-execute conn "CREATE TABLE person (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")
      (sql-execute conn "INSERT INTO person (name, age) VALUES (?, ?)" "Alice" 30)
      (sql-execute conn "INSERT INTO person (name, age) VALUES (?, ?)" "Bob" 45)
      (sql-query conn "SELECT id, name, age FROM person ORDER BY id")
      SCHEME
  end

  it "queries with bound params filtering rows" do
    w(<<-SCHEME).should eq(%(#((("name" . "Bob")))))
      (define conn (sql-open ":memory:"))
      (sql-execute conn "CREATE TABLE person (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")
      (sql-execute conn "INSERT INTO person (name, age) VALUES (?, ?)" "Alice" 30)
      (sql-execute conn "INSERT INTO person (name, age) VALUES (?, ?)" "Bob" 45)
      (sql-query conn "SELECT name FROM person WHERE age > ?" 40)
      SCHEME
  end

  it "round-trips float and null column values" do
    w(<<-SCHEME).should eq("(#t #t)")
      (define conn (sql-open ":memory:"))
      (define row (vector-ref (sql-query conn "SELECT 1.5 AS a, NULL AS b") 0))
      (list (= 1.5 (cdr (assoc "a" row))) (null? (cdr (assoc "b" row))))
      SCHEME
  end

  it "queries a BLOB column back as a bytevector, preserving its bytes" do
    w(<<-SCHEME).should eq("(#t 3)")
      (define conn (sql-open ":memory:"))
      (define b (cdr (assoc "b" (vector-ref (sql-query conn "SELECT x'010203' AS b") 0))))
      (list (bytevector? b) (bytevector-length b))
      SCHEME
  end

  it "returns a scalar value" do
    w(<<-SCHEME).should eq("2")
      (define conn (sql-open ":memory:"))
      (sql-execute conn "CREATE TABLE person (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")
      (sql-execute conn "INSERT INTO person (name, age) VALUES (?, ?)" "Alice" 30)
      (sql-execute conn "INSERT INTO person (name, age) VALUES (?, ?)" "Bob" 45)
      (sql-scalar conn "SELECT COUNT(*) FROM person")
      SCHEME
  end

  it "closes a connection without raising" do
    w(%((begin (sql-close (sql-open ":memory:")) "ok"))).should eq(%("ok"))
  end

  it "raises a SchemeRuntimeError on invalid sql" do
    expect_raises(Scheme::SchemeRuntimeError, /sql-execute:/) do
      run(%((sql-execute (sql-open ":memory:") "NOT VALID SQL")))
    end
  end

  it "raises a SchemeRuntimeError on scalar with no rows" do
    expect_raises(Scheme::SchemeRuntimeError, /sql-scalar:/) do
      run(<<-SCHEME)
        (define conn (sql-open ":memory:"))
        (sql-execute conn "CREATE TABLE person (id INTEGER PRIMARY KEY)")
        (sql-scalar conn "SELECT id FROM person WHERE id = 999")
        SCHEME
    end
  end

  it "opens a file-backed connection with explicit 'reader/'writer pool sizes and round-trips a write through a read" do
    path = File.tempname("sql_spec", ".sqlite3")
    begin
      w(<<-SCHEME).should eq("2")
        (define conn (sql-open #{path.inspect} 'reader 4 'writer 1))
        (sql-execute conn "CREATE TABLE person (id INTEGER PRIMARY KEY, name TEXT)")
        (sql-execute conn "INSERT INTO person (name) VALUES (?)" "Alice")
        (sql-execute conn "INSERT INTO person (name) VALUES (?)" "Bob")
        (sql-scalar conn "SELECT COUNT(*) FROM person")
        SCHEME
    ensure
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end

  it "accepts a single 'reader or 'writer keyword alone" do
    path = File.tempname("sql_spec", ".sqlite3")
    begin
      w(%((sql-connection? (sql-open #{path.inspect} 'reader 2)))).should eq("#t")
    ensure
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end

  it "ignores 'reader/'writer keywords for \":memory:\" without error" do
    w(%((sql-connection? (sql-open ":memory:" 'reader 4 'writer 1)))).should eq("#t")
  end

  it "raises a SchemeRuntimeError on an odd number of trailing keyword arguments" do
    expect_raises(Scheme::SchemeRuntimeError, /keyword arguments must come in/) do
      run(%((sql-open ":memory:" 'reader)))
    end
  end

  it "raises a SchemeRuntimeError on an unknown keyword" do
    expect_raises(Scheme::SchemeRuntimeError, /unknown keyword/) do
      run(%((sql-open ":memory:" 'bogus 4)))
    end
  end

  it "raises a SchemeRuntimeError when a keyword position isn't a symbol" do
    expect_raises(Scheme::SchemeRuntimeError, /expected a keyword symbol/) do
      run(%((sql-open ":memory:" "reader" 4)))
    end
  end

  it "csv-import! loads a headered CSV, inferring TEXT columns from the header row" do
    path = File.tempfile("csvquery-sql-import", ".csv") { |file| file.print "name,dept,salary\nAlice,eng,100\nBob,sales,200\n" }.path
    w(<<-SCHEME).should eq(%(#((("name" . "Alice") ("dept" . "eng") ("salary" . "100")) (("name" . "Bob") ("dept" . "sales") ("salary" . "200")))))
      (define conn (sql-open ":memory:"))
      (csv-import! conn "emp" #{path.inspect})
      (sql-query conn "select * from emp order by name")
      SCHEME

  ensure
    File.delete?(path) if path
  end

  it "csv-import! reports the imported row count" do
    path = File.tempfile("csvquery-sql-import", ".csv") { |file| file.print "a,b\n1,2\n3,4\n5,6\n" }.path
    w(%[
      (let ((conn (sql-open ":memory:")))
        (csv-import! conn "t" #{path.inspect}))
    ]).should eq("3")
  ensure
    File.delete?(path) if path
  end

  it "csv-import! loads a headerless CSV via an explicit 'columns alist with real numeric types" do
    path = File.tempfile("csvquery-sql-import", ".csv") { |file| file.print "eng\t1\nsales\t2\n" }.path
    w(<<-SCHEME).should eq("3")
      (define conn (sql-open ":memory:"))
      (csv-import! conn "t" #{path.inspect}
                   'columns (list (cons "dept" "TEXT") (cons "n" "INTEGER"))
                   'separator #\\tab)
      (sql-scalar conn "select sum(n) from t where dept = 'sales' or dept = 'eng'")
      SCHEME

  ensure
    File.delete?(path) if path
  end

  it "csv-import! loads a headered CSV, overriding just some column types via 'types while keeping the header-detected names" do
    path = File.tempfile("csvquery-sql-import", ".csv") { |file| file.print "dept,n\neng,1\nsales,2\neng,3\n" }.path
    w(<<-SCHEME).should eq("4")
      (define conn (sql-open ":memory:"))
      (csv-import! conn "t" #{path.inspect} 'types (list (cons "n" "INTEGER")))
      (sql-scalar conn "select sum(n) from t where dept = 'eng'")
      SCHEME

  ensure
    File.delete?(path) if path
  end

  it "csv-import! defaults an unmentioned header column to TEXT even when 'types is given" do
    path = File.tempfile("csvquery-sql-import", ".csv") { |file| file.print "dept,n\neng,1\n" }.path
    w(<<-SCHEME).should eq(%[(("dept" . "eng") ("n" . 1))])
      (define conn (sql-open ":memory:"))
      (csv-import! conn "t" #{path.inspect} 'types (list (cons "n" "INTEGER")))
      (vector-ref (sql-query conn "select * from t") 0)
      SCHEME

  ensure
    File.delete?(path) if path
  end

  it "csv-import! raises when 'types is combined with 'columns" do
    path = File.tempfile("csvquery-sql-import", ".csv") { |file| file.print "eng\t1\n" }.path
    expect_raises(Scheme::SchemeRuntimeError, /'types cannot be combined with 'columns/) do
      run(%[
        (csv-import! (sql-open ":memory:") "t" #{path.inspect}
                     'columns (list (cons "dept" "TEXT") (cons "n" "INTEGER"))
                     'types (list (cons "n" "INTEGER"))
                     'separator #\\tab)
      ])
    end
  ensure
    File.delete?(path) if path
  end

  it "csv-import! uses a fully custom 'create-table statement verbatim, with a header row for column names" do
    path = File.tempfile("csvquery-sql-import", ".csv") { |file| file.print "dept,n\neng,1\nsales,2\neng,3\n" }.path
    w(<<-SCHEME).should eq("4")
      (define conn (sql-open ":memory:"))
      (csv-import! conn "t" #{path.inspect}
                   'create-table "CREATE TABLE t (dept TEXT NOT NULL, n INTEGER CHECK (n > 0))")
      (sql-scalar conn "select sum(n) from t where dept = 'eng'")
      SCHEME

  ensure
    File.delete?(path) if path
  end

  it "csv-import!'s custom 'create-table's own constraints are actually enforced (not just accepted verbatim)" do
    path = File.tempfile("csvquery-sql-import", ".csv") { |file| file.print "dept,n\neng,-1\n" }.path
    expect_raises(Scheme::SchemeRuntimeError, /CHECK constraint failed/) do
      run(%[
        (csv-import! (sql-open ":memory:") "t" #{path.inspect}
                     'create-table "CREATE TABLE t (dept TEXT NOT NULL, n INTEGER CHECK (n > 0))")
      ])
    end
  ensure
    File.delete?(path) if path
  end

  it "csv-import! raises when 'types is combined with 'create-table" do
    path = File.tempfile("csvquery-sql-import", ".csv") { |file| file.print "dept,n\neng,1\n" }.path
    expect_raises(Scheme::SchemeRuntimeError, /'types cannot be combined with 'create-table/) do
      run(%[
        (csv-import! (sql-open ":memory:") "t" #{path.inspect}
                     'create-table "CREATE TABLE t (dept TEXT, n INTEGER)"
                     'types (list (cons "n" "INTEGER")))
      ])
    end
  ensure
    File.delete?(path) if path
  end

  it "csv-import! raises on an empty file with no explicit columns" do
    path = File.tempfile("csvquery-sql-import", ".csv") { |_| }.path
    expect_raises(Scheme::SchemeRuntimeError, /empty CSV file/) do
      run(%[(csv-import! (sql-open ":memory:") "t" #{path.inspect})])
    end
  ensure
    File.delete?(path) if path
  end

  it "csv-import! accepts a tiny 'chunk-size, forcing many internal refills, without affecting results" do
    path = File.tempfile("csvquery-sql-import", ".csv") { |file| file.print "name,dept,salary\nAlice,eng,100\nBob,sales,200\n" }.path
    w(<<-SCHEME).should eq(%(#((("name" . "Alice") ("dept" . "eng") ("salary" . "100")) (("name" . "Bob") ("dept" . "sales") ("salary" . "200")))))
      (define conn (sql-open ":memory:"))
      (csv-import! conn "emp" #{path.inspect} 'chunk-size 4)
      (sql-query conn "select * from emp order by name")
      SCHEME

  ensure
    File.delete?(path) if path
  end

  it "csv-import! raises on an unknown keyword" do
    path = File.tempfile("csvquery-sql-import", ".csv") { |file| file.print "a\n1\n" }.path
    expect_raises(Scheme::SchemeRuntimeError, /unknown keyword/) do
      run(%[(csv-import! (sql-open ":memory:") "t" #{path.inspect} 'bogus 1)])
    end
  ensure
    File.delete?(path) if path
  end
end
