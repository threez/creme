require "../../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, "(import (creme introspection)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, "(import (creme introspection)) #{src}")
end

describe "introspection module" do
  it "macro? is false for an ordinary procedure" do
    w(%((macro? car))).should eq("#f")
  end

  it "gensym returns distinct symbols, optionally with a given prefix" do
    w(%((eq? (gensym) (gensym)))).should eq("#f")
    w(%((symbol->string (gensym "foo")))).should match(/\A"foo/)
  end

  it "record-fields returns a record's field values, in declared order" do
    w(<<-SCHEME).should eq("(1 2)")
      (define-record-type <pt> (make-pt x y) pt? (x pt-x) (y pt-y))
      (record-fields (make-pt 1 2))
      SCHEME
  end

  it "record-fields works generically across distinct record types" do
    w(<<-SCHEME).should eq(%((("a") (1 2 3))))
      (define-record-type <one> (make-one a) one? (a one-a))
      (define-record-type <three> (make-three a b c) three? (a three-a) (b three-b) (c three-c))
      (list (record-fields (make-one "a")) (record-fields (make-three 1 2 3)))
      SCHEME
  end

  it "raises for a non-record argument" do
    expect_raises(Scheme::SchemeRuntimeError, /expected a record instance/) do
      run(%((record-fields 42)))
    end
  end
end
