require "../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (creme css)) #{src}").write_string
end

describe "css module" do
  it "renders a single rule with multiple declarations" do
    w(%q((css->string '((body (font-family "sans-serif") (margin 0))))))
      .should eq(%("body {\\n  font-family: sans-serif;\\n  margin: 0;\\n}\\n"))
  end

  it "accepts a string property name same as a symbol one" do
    w(%q((css->string '((body ("font-family" "sans-serif"))))))
      .should eq(%("body {\\n  font-family: sans-serif;\\n}\\n"))
  end

  it "renders a comma-separated selector group" do
    w(%q((css->string '((("th" "td") (padding "4px"))))))
      .should eq(%("th, td {\\n  padding: 4px;\\n}\\n"))
  end

  it "renders multiple rules concatenated" do
    w(%q((css->string '((body (margin 0)) (".x" (color "red"))))))
      .should eq(%("body {\\n  margin: 0;\\n}\\n.x {\\n  color: red;\\n}\\n"))
  end

  it "passes raw content through unescaped" do
    w(%q((css->string '((raw "@media (min-width: 1px) { }")))))
      .should eq(%("@media (min-width: 1px) { }"))
  end

  it "combines a nested descendant selector with its parent" do
    w(%q((css->string '((".todo-app" (max-width "28rem") (".title" (color "#888")))))))
      .should eq(%(".todo-app {\\n  max-width: 28rem;\\n}\\n.todo-app .title {\\n  color: #888;\\n}\\n"))
  end

  it "combines a nested '&' selector with its parent, with no separating space" do
    w(%q((css->string '((".todo-app" (max-width "28rem") ("&.done" (opacity "0.6")))))))
      .should eq(%(".todo-app {\\n  max-width: 28rem;\\n}\\n.todo-app.done {\\n  opacity: 0.6;\\n}\\n"))
  end

  it "combines a comma-separated group nested under a comma-separated parent as a cross product" do
    w(%q((css->string '((("x" "y") (color "red") (("a" "b") (color "blue")))))))
      .should eq(%("x, y {\\n  color: red;\\n}\\nx a, x b, y a, y b {\\n  color: blue;\\n}\\n"))
  end

  describe "css! (compile-time template folding)" do
    it "matches css->string for a fully static stylesheet" do
      w(%((css! ((body (font-family "sans-serif") (margin 0))))))
        .should eq(%("body {\\n  font-family: sans-serif;\\n  margin: 0;\\n}\\n"))
    end

    it "matches css->string for nested static rules" do
      w(%((css! ((".todo-app" (max-width "28rem") (".title" (color "#888")) ("&.done" (opacity "0.6")))))))
        .should eq(%(".todo-app {\\n  max-width: 28rem;\\n}\\n.todo-app .title {\\n  color: #888;\\n}\\n.todo-app.done {\\n  opacity: 0.6;\\n}\\n"))
    end

    it "matches css->string for a comma-separated selector group" do
      w(%((css! ((("th" "td") (padding "4px"))))))
        .should eq(%("th, td {\\n  padding: 4px;\\n}\\n"))
    end

    it "matches css->string for a dynamic declaration value" do
      w(<<-SCHEME).should eq(%("body {\\n  color: red;\\n}\\n"))
        (define c "red")
        (css! `((body (color ,c))))
        SCHEME
    end

    it "matches css->string for a dynamic value inside a nested rule" do
      w(<<-SCHEME).should eq(%(".todo-app {\\n  max-width: 28rem;\\n}\\n.todo-app .title {\\n  color: red;\\n}\\n"))
        (define c "red")
        (css! `((".todo-app" (max-width "28rem") (".title" (color ,c)))))
        SCHEME
    end

    it "matches css->string for multiple rules, one fully dynamic" do
      w(<<-SCHEME).should eq(%("body {\\n  margin: 0;\\n}\\n.y {\\n  color: blue;\\n}\\n"))
        (define dyn-rule '(".y" (color "blue")))
        (css! `((body (margin 0)) ,dyn-rule))
        SCHEME
    end

    it "matches css->string for raw content" do
      w(%((css! ((raw "@media (min-width: 1px) { }")))))
        .should eq(%("@media (min-width: 1px) { }"))
    end
  end

  describe "css-write! (folding into an existing port)" do
    it "matches css! for a dynamic declaration value, writing into a caller-supplied port" do
      w(<<-SCHEME).should eq(%("body {\\n  color: red;\\n}\\n"))
        (define c "red")
        (let ((port (open-output-string)))
          (css-write! port `((body (color ,c))))
          (get-output-string port))
        SCHEME
    end

    it "matches css! for a fully static stylesheet" do
      w(%((let ((port (open-output-string)))
            (css-write! port ((body (font-family "sans-serif"))))
            (get-output-string port))))
        .should eq(%("body {\\n  font-family: sans-serif;\\n}\\n"))
    end
  end
end
