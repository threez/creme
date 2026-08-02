require "../../../../spec_helper"

private def rendered(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, <<-SCHEME).as(Creme::SchemeStr).value
    (import (scheme base) (scheme write) (scheme cxr) (scheme eval) (scheme repl) (creme html) (creme syntax slim))
    (let* ((forms (read-program #{src.inspect} "t" (quote ())))
           (html-write-form (cadr forms))
           (node (eval (caddr html-write-form) (interaction-environment))))
      (html->string node))
    SCHEME
end

describe "(creme syntax slim)" do
  it "renders a plain tag with text content" do
    rendered("h1 Todo List").should eq("<h1>Todo List</h1>")
  end

  it "expands class/id shorthand and defaults a bare .class/#id to div" do
    rendered("div.todo-app#main Hi").should eq(%(<div class="todo-app" id="main">Hi</div>))
    rendered(".todo-app Hi").should eq(%(<div class="todo-app">Hi</div>))
  end

  it "parses parenthesized attributes" do
    rendered(%(input(type="text" name="title"))).should eq(%(<input type="text" name="title">))
  end

  it "nests children by indentation" do
    rendered("ul\n  li a\n  li b").should eq("<ul><li>a</li><li>b</li></ul>")
  end

  it "splices a standalone '=' line's expression value" do
    rendered("p\n  = (string-append \"a\" \"b\")").should eq("<p>ab</p>")
  end

  it "splices an inline 'tag = expr' expression value" do
    rendered("p = (string-append \"a\" \"b\")").should eq("<p>ab</p>")
  end

  it "renders multiple top-level siblings as a fragment" do
    rendered("h1 A\np B").should eq("<h1>A</h1><p>B</p>")
  end

  it "escapes text content" do
    rendered("p <script>").should eq("<p>&lt;script&gt;</p>")
  end

  it "raises when a '=' line has children" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    expect_raises(Creme::SchemeRuntimeError, /cannot have children/) do
      Creme.run_source(interp, %[(import (scheme base) (creme syntax slim)) (read-program "= 1\\n  li a" "t" (quote ()))])
    end
  end
end

describe "(creme syntax slim) #lang define-mode ((export name) (params ...))" do
  it "defines an ordinary procedure of the declared params, parsed/compiled once" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    Creme.run_source(interp, <<-SCHEME)
      #lang (creme syntax slim) (export row) (params id done title)
      li(class=(if done "done" "pending")) = title
      SCHEME
    row = interp.global.get("row")
    interp.apply(row, [Creme::SchemeInt.new(1_i64), Creme::TRUE, Creme::SchemeStr.new("Write report")] of Creme::SchemeValue)
      .as(Creme::SchemeStr).value.should eq(%(<li class="done">Write report</li>))
    interp.apply(row, [Creme::SchemeInt.new(2_i64), Creme::FALSE, Creme::SchemeStr.new("Review PR")] of Creme::SchemeValue)
      .as(Creme::SchemeStr).value.should eq(%(<li class="pending">Review PR</li>))
  end

  it "defines a zero-argument procedure when (params ...) is omitted" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    Creme.run_source(interp, "#lang (creme syntax slim) (export greeting)\nh1 Hello\n")
    greeting = interp.global.get("greeting")
    interp.apply(greeting, [] of Creme::SchemeValue).as(Creme::SchemeStr).value.should eq("<h1>Hello</h1>")
  end

  it "an (import ...) header-arg makes an extra library visible to the template's own expressions" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    Creme.run_source(interp, <<-SCHEME)
      #lang (creme syntax slim) (export link) (params id) (import (creme path) (creme format))
      a(href=(path 'todos id)) Link
      SCHEME
    link = interp.global.get("link")
    interp.apply(link, [Creme::SchemeInt.new(5_i64)] of Creme::SchemeValue)
      .as(Creme::SchemeStr).value.should eq(%(<a href="/todos/5">Link</a>))
  end
end
