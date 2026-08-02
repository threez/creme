require "../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (creme path) (creme format)) #{src}").write_string
end

describe "path module" do
  it "builds an absolute path from quoted symbol segments" do
    w(%((path 'todos 'complete))).should eq(%("/todos/complete"))
  end

  it "folds literal segments around a dynamic one, same as hand-written string-append" do
    w(<<-SCHEME).should eq(%("/todos/42/complete"))
      (define id 42)
      (path 'todos id 'complete)
      SCHEME
  end

  it "stringifies a dynamic segment via symbol->string/number->string as appropriate" do
    w(<<-SCHEME).should eq(%("/a/1/b"))
      (define x 1)
      (path 'a x 'b)
      SCHEME
  end

  it "accepts string and number literal segments too" do
    w(%((path "todos" 3 'complete))).should eq(%("/todos/3/complete"))
  end

  it "returns \"/\" for zero segments" do
    w(%((path))).should eq(%("/"))
  end

  it "builds a relative path with no leading slash" do
    w(<<-SCHEME).should eq(%("todos/42"))
      (define id 42)
      (rel-path 'todos id)
      SCHEME
  end

  it "returns \"\" for zero segments in rel-path" do
    w(%((rel-path))).should eq(%(""))
  end

  it "escapes a literal ~ in a static segment so it isn't misread as a format directive" do
    w(<<-SCHEME).should eq(%("/a~b/1"))
      (define id 1)
      (path "a~b" id)
      SCHEME
  end

  it "handles multiple dynamic segments in one path" do
    w(<<-SCHEME).should eq(%("/a/1/b/2"))
      (define id 1)
      (path 'a id 'b (* id 2))
      SCHEME
  end
end
