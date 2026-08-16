require "../../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (creme tui)) #{src}").write_string
end

describe "tui module" do
  it "constructs named, indexed, rgb, and gray colors" do
    w(%((tui-color-named 'red))).should match(/#<tui-color>/)
    w(%((tui-color-index 208))).should match(/#<tui-color>/)
    w(%((tui-color-rgb 5 2 0))).should match(/#<tui-color>/)
    w(%((tui-color-gray 10))).should match(/#<tui-color>/)
  end

  it "raises for an out-of-range color index" do
    expect_raises(Creme::SchemeRuntimeError, /tui-color-index:/) { w("(tui-color-index 999)") }
  end

  it "raises for an unknown named color" do
    expect_raises(Creme::SchemeRuntimeError, /tui-color-named: unknown color name/) { w("(tui-color-named 'periwinkle)") }
  end

  it "builds a style from an alist" do
    w(%((tui-style (list (cons "bold" #t) (cons "fg" (tui-color-named 'red)))))).should match(/#<tui-style>/)
  end

  it "raises for an unknown style key" do
    expect_raises(Creme::SchemeRuntimeError, /tui-style: unknown style key/) do
      w(%((tui-style (list (cons "blorp" #t)))))
    end
  end

  it "creates a text-edit pane and reads its value" do
    w(%((tui-text-edit-value (tui-text-edit "hello")))).should eq(%("hello"))
  end

  it "text-edit defaults to an empty value" do
    w("(tui-text-edit-value (tui-text-edit))").should eq(%(""))
  end

  it "raises when text-edit-set-highlighter! is given a non-text-edit scrollable" do
    expect_raises(Creme::SchemeRuntimeError, /tui-text-edit-set-highlighter!: expected a tui-text-edit pane/) do
      w(<<-SCHEME)
        (define pane
          (tui-make-scrollable (lambda () "") (lambda () 0) (lambda (buf) #f) (lambda (ev) #f) (lambda () "")))
        (tui-text-edit-set-highlighter! pane (lambda (line) (list)))
        SCHEME
    end
  end

  it "raises when text-edit-value is given a non-text-edit scrollable" do
    expect_raises(Creme::SchemeRuntimeError, /tui-text-edit-value: expected a tui-text-edit pane/) do
      w(<<-SCHEME)
        (define pane
          (tui-make-scrollable (lambda () "") (lambda () 0) (lambda (buf) #f) (lambda (ev) #f) (lambda () "")))
        (tui-text-edit-value pane)
        SCHEME
    end
  end
end
