require "../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (creme escm)) #{src}").write_string
end

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (creme escm)) #{src}")
end

describe "escm module" do
  it "passes plain text through verbatim" do
    w(%((escm-render-string "hello world" '()))).should eq(%("hello world"))
  end

  it "interpolates a <%= %> expression" do
    w(%((escm-render-string "hi, <%= name %>!" (list (cons 'name "Alice"))))).should eq(%("hi, Alice!"))
  end

  it "evaluates a <% %> code block for side effects only" do
    w("(escm-render-string \"<% (display 1) (display 2) %>done\" '())").should eq(%("12done"))
  end

  it "mixes text, code, and expr segments" do
    w(%((escm-render-string "<% (define x 5) %>x is <%= x %>." '()))).should eq(%("x is 5."))
  end

  it "installs locals as bindings visible to embedded code" do
    w(%((escm-render-string "<%= (* n 2) %>" (list (cons 'n 21))))).should eq(%("42"))
  end

  it "does not leak one render's locals into another render of the same compiled template" do
    w(<<-SCHEME).should eq(%(("a" "b")))
      (define tmpl (escm-compile "<%= who %>"))
      (list (escm-render tmpl (list (cons 'who "a")))
            (escm-render tmpl (list (cons 'who "b"))))
      SCHEME
  end

  it "supports a <% %> block with more than one top-level form" do
    w(<<-SCHEME).should eq(%("3"))
      (escm-render-string "<% (define a 1) (define b 2) %><%= (+ a b) %>" '())
      SCHEME
  end

  it "raises at compile time on an unterminated tag" do
    expect_raises(Creme::SchemeError) { run(%((escm-compile "<%= 1 + 1"))) }
  end

  it "raises at compile time on an empty <%= %>" do
    expect_raises(Creme::SchemeError) { run(%((escm-compile "<%=  %>"))) }
  end

  it "leaves an ordinary < not starting a tag as literal text" do
    w(%((escm-render-string "1 < 2" '()))).should eq(%("1 < 2"))
  end
end
