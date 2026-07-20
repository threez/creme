require "../../../../spec_helper"

private def rendered(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, <<-SCHEME).as(Scheme::SchemeStr).value
    (import (scheme base) (scheme write) (scheme cxr) (creme css) (creme syntax scss))
    (let* ((forms (read-program #{src.inspect} "t" (quote ())))
           (css-render-form (cadr forms))
           (rules (cadr (caddr css-render-form))))
      (css->string rules))
    SCHEME
end

private def rules_data(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, <<-SCHEME).write_string
    (import (scheme base) (scheme write) (scheme cxr) (creme syntax scss))
    (let* ((forms (read-program #{src.inspect} "t" (quote ())))
           (css-render-form (cadr forms)))
      (cadr (caddr css-render-form)))
    SCHEME
end

describe "(creme syntax scss)" do
  it "parses a flat declaration" do
    rules_data("a { color: red; }").should eq(%[(("a" (color "red")))])
  end

  it "nests rules, letting (creme css) combine selectors with a descendant combinator" do
    rendered(".todo-app {\n  max-width: 28rem;\n  .title { color: red; }\n}\n")
      .should eq(".todo-app {\n  max-width: 28rem;\n}\n.todo-app .title {\n  color: red;\n}\n")
  end

  it "combines a leading '&' with the parent selector, no separating space" do
    rendered(".todo-app {\n  &.done { opacity: 0.6; }\n}\n")
      .should eq(".todo-app.done {\n  opacity: 0.6;\n}\n")
  end

  it "substitutes $variables into later declaration values" do
    rendered("$accent: #888;\na { color: $accent; }\n").should eq("a {\n  color: #888;\n}\n")
  end

  it "splits a comma-separated selector group" do
    rules_data("a, b { color: red; }").should eq(%[((("a" "b") (color "red")))])
  end

  it "skips // and /* */ comments between statements" do
    rendered("// leading comment\na { color: red; } /* trailing */\n").should eq("a {\n  color: red;\n}\n")
  end

  it "raises on an undefined variable" do
    interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
    expect_raises(Scheme::SchemeRuntimeError, /undefined variable/) do
      Scheme.run_source(interp, %[(import (scheme base) (scheme cxr) (creme syntax scss)) (read-program "a { color: $nope; }" "t" (quote ()))])
    end
  end

  it "raises on a declaration missing a ':'" do
    interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
    expect_raises(Scheme::SchemeRuntimeError, /expected ':'/) do
      Scheme.run_source(interp, %[(import (scheme base) (scheme cxr) (creme syntax scss)) (read-program "a { oops; }" "t" (quote ()))])
    end
  end
end
