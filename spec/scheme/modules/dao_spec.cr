require "../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (creme dao) (creme sql)) #{src}").write_string
end

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (creme dao) (creme sql)) #{src}")
end

private def fresh_widget_dao : String
  <<-SCM
  (define conn (sql-open ":memory:"))
  (define-dao widget conn
    (id integer primary-key auto-increment)
    (name text not-null)
    (qty integer not-null (default 0))
    (active bool not-null (default #f)))
  SCM
end

describe "dao module" do
  it "creates the table and inserts, returning the new row's id" do
    w(<<-SCM).should eq("1")
      #{fresh_widget_dao}
      (widget-create! 'name "bolt" 'qty 5)
      SCM
  end

  it "increments the id on a second insert" do
    w(<<-SCM).should eq("2")
      #{fresh_widget_dao}
      (widget-create! 'name "bolt" 'qty 5)
      (widget-create! 'name "nut" 'qty 3)
      SCM
  end

  it "applies a column DEFAULT constraint when a create! call omits that column" do
    w(<<-SCM).should eq("0")
      #{fresh_widget_dao}
      (define id (dao-insert! conn 'widget (list 'name "bare")))
      (dao-ref (widget-find id) 'qty)
      SCM
  end

  it "dao-ref reads a created row back via widget-find" do
    w(<<-SCM).should eq(%("bolt"))
      #{fresh_widget_dao}
      (define id (widget-create! 'name "bolt" 'qty 5))
      (dao-ref (widget-find id) 'name)
      SCM
  end

  it "widget-find returns #f for a missing id" do
    w(<<-SCM).should eq("#f")
      #{fresh_widget_dao}
      (widget-find 999)
      SCM
  end

  it "widget-all returns every row ordered by id" do
    w(<<-SCM).should eq(%(("a" "b" "c")))
      #{fresh_widget_dao}
      (widget-create! 'name "a" 'qty 1)
      (widget-create! 'name "b" 'qty 2)
      (widget-create! 'name "c" 'qty 3)
      (map (lambda (row) (dao-ref row 'name)) (widget-all))
      SCM
  end

  it "widget-update! mutates the row and returns the id" do
    w(<<-SCM).should eq("1")
      #{fresh_widget_dao}
      (define id (widget-create! 'name "bolt" 'qty 5))
      (widget-update! id 'qty 42)
      SCM

    w(<<-SCM).should eq("42")
      #{fresh_widget_dao}
      (define id (widget-create! 'name "bolt" 'qty 5))
      (widget-update! id 'qty 42)
      (dao-ref (widget-find id) 'qty)
      SCM
  end

  it "widget-delete! removes the row" do
    w(<<-SCM).should eq("#f")
      #{fresh_widget_dao}
      (define id (widget-create! 'name "bolt" 'qty 5))
      (widget-delete! id)
      (widget-find id)
      SCM
  end

  it "widget-count with no args counts every row" do
    w(<<-SCM).should eq("2")
      #{fresh_widget_dao}
      (widget-create! 'name "a" 'qty 1)
      (widget-create! 'name "b" 'qty 0)
      (widget-count)
      SCM
  end

  it "widget-count with a Scheme predicate counts only matching rows" do
    w(<<-SCM).should eq("1")
      #{fresh_widget_dao}
      (widget-create! 'name "a" 'qty 1)
      (widget-create! 'name "b" 'qty 0)
      (widget-count (lambda (row) (= (dao-ref row 'qty) 0)))
      SCM
  end

  it "a not-null violation raises" do
    expect_raises(Creme::SchemeRuntimeError) do
      run(<<-SCM)
        #{fresh_widget_dao}
        (dao-insert! conn 'widget (list 'qty 1))
        SCM
    end
  end

  it "applies a bool column's DEFAULT when a create! call omits that column, readable via the generated predicate" do
    w(<<-SCM).should eq("#f")
      #{fresh_widget_dao}
      (define id (widget-create! 'name "bolt" 'qty 5))
      (widget-active? (widget-find id))
      SCM
  end

  it "the generated bool predicate reads back a value passed directly as #t/#f on create!" do
    w(<<-SCM).should eq("#t")
      #{fresh_widget_dao}
      (define id (widget-create! 'name "bolt" 'qty 5 'active #t))
      (widget-active? (widget-find id))
      SCM
  end

  it "the generated bool predicate reflects a flip via update!" do
    w(<<-SCM).should eq("#t")
      #{fresh_widget_dao}
      (define id (widget-create! 'name "bolt" 'qty 5))
      (widget-update! id 'active #t)
      (widget-active? (widget-find id))
      SCM
  end

  it "define-dao is idempotent (CREATE TABLE IF NOT EXISTS)" do
    w(<<-SCM).should eq("1")
      (define conn (sql-open ":memory:"))
      (define-dao widget conn (id integer primary-key auto-increment) (name text not-null))
      (define-dao widget2 conn (id integer primary-key auto-increment) (name text not-null))
      (widget2-create! 'name "x")
      SCM
  end
end
