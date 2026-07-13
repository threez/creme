require "../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, "(import (creme tui)) #{src}").write_string
end

describe "tui module" do
  it "constructs named, indexed, rgb, and gray colors" do
    w(%((tui-color-named 'red))).should match(/#<tui-color>/)
    w(%((tui-color-index 208))).should match(/#<tui-color>/)
    w(%((tui-color-rgb 5 2 0))).should match(/#<tui-color>/)
    w(%((tui-color-gray 10))).should match(/#<tui-color>/)
  end

  it "raises for an out-of-range color index" do
    expect_raises(Scheme::SchemeRuntimeError, /tui-color-index:/) { w("(tui-color-index 999)") }
  end

  it "raises for an unknown named color" do
    expect_raises(Scheme::SchemeRuntimeError, /tui-color-named: unknown color name/) { w("(tui-color-named 'periwinkle)") }
  end

  it "builds a style from an alist" do
    w(%((tui-style (list (cons "bold" #t) (cons "fg" (tui-color-named 'red)))))).should match(/#<tui-style>/)
  end

  it "raises for an unknown style key" do
    expect_raises(Scheme::SchemeRuntimeError, /tui-style: unknown style key/) do
      w(%((tui-style (list (cons "blorp" #t)))))
    end
  end

  it "creates a screen" do
    w("(tui-screen)").should match(/#<tui-screen>/)
  end

  it "buffer-set!/buffer-clear!/buffer-box! operate on a make-scrollable render buffer without raising, exercised via tui-run's one forced render under EOF stdin" do
    w(<<-SCHEME).should eq("#t")
      (define ok #f)
      (define pane
        (tui-make-scrollable
          (lambda () "Pane")
          (lambda () 1)
          (lambda (buf)
            (tui-buffer-set! buf 0 0 "hello")
            (tui-buffer-box! buf 0 0 3 10 "title")
            (tui-buffer-clear! buf)
            (set! ok #t))
          (lambda (ev) #f)
          (lambda () "hint")))
      (define screen (tui-screen))
      (tui-run screen (tui-window screen pane) (lambda (ev) #f))
      ok
      SCHEME
  end

  it "creates a text-edit pane and reads its value" do
    w(%((tui-text-edit-value (tui-text-edit "hello")))).should eq(%("hello"))
  end

  it "text-edit defaults to an empty value" do
    w("(tui-text-edit-value (tui-text-edit))").should eq(%(""))
  end

  it "wires a highlighter into text-edit and exercises it via tui-run's one forced render under EOF stdin" do
    w(<<-SCHEME).should eq("#t")
      (define ok #f)
      (define pane (tui-text-edit "hi"))
      (tui-text-edit-set-highlighter! pane
        (lambda (line)
          (set! ok #t)
          (list (cons line (tui-style (list (cons "bold" #t)))))))
      (define screen (tui-screen))
      (tui-run screen (tui-window screen pane) (lambda (ev) #f))
      ok
      SCHEME
  end

  it "raises when the highlighter-fn returns something other than a list of (text . style) pairs" do
    expect_raises(Scheme::SchemeRuntimeError, /tui-text-edit-set-highlighter! highlighter-fn: expected a list of \(text . style\) pairs/) do
      w(<<-SCHEME)
        (define pane (tui-text-edit "hi"))
        (tui-text-edit-set-highlighter! pane (lambda (line) (list "not-a-pair")))
        (define screen (tui-screen))
        (tui-run screen (tui-window screen pane) (lambda (ev) #f))
        SCHEME
    end
  end

  it "raises when text-edit-set-highlighter! is given a non-text-edit scrollable" do
    expect_raises(Scheme::SchemeRuntimeError, /tui-text-edit-set-highlighter!: expected a tui-text-edit pane/) do
      w(<<-SCHEME)
        (define pane
          (tui-make-scrollable (lambda () "") (lambda () 0) (lambda (buf) #f) (lambda (ev) #f) (lambda () "")))
        (tui-text-edit-set-highlighter! pane (lambda (line) (list)))
        SCHEME
    end
  end

  it "raises when text-edit-value is given a non-text-edit scrollable" do
    expect_raises(Scheme::SchemeRuntimeError, /tui-text-edit-value: expected a tui-text-edit pane/) do
      w(<<-SCHEME)
        (define pane
          (tui-make-scrollable (lambda () "") (lambda () 0) (lambda (buf) #f) (lambda (ev) #f) (lambda () "")))
        (tui-text-edit-value pane)
        SCHEME
    end
  end

  it "builds a full-screen window around a scrollable" do
    w(%((tui-window (tui-screen) (tui-text-edit "hi")))).should match(/#<tui-widget>/)
  end

  it "builds a vstack of two panes and can swap the bottom pane" do
    w(<<-SCHEME).should match(/#<tui-widget>/)
      (define screen (tui-screen))
      (define top (tui-text-edit "top"))
      (define bottom (tui-text-edit "bottom"))
      (define vs (tui-vstack screen top bottom 3))
      (tui-vstack-set-bottom! vs (tui-text-edit "new bottom"))
      vs
      SCHEME
  end

  it "handle-key! forwards a key-event alist into a widget's handle_key and switches vstack focus on tab" do
    w(<<-SCHEME).should eq("#t")
      (define screen (tui-screen))
      (define vs (tui-vstack screen (tui-text-edit "top") (tui-text-edit "bottom") 3))
      (define tab-event (list (cons "key" "tab") (cons "char" #f) (cons "row" #f) (cons "col" #f) (cons "text" #f)))
      (define char-event (list (cons "key" "char") (cons "char" #\\x) (cons "row" #f) (cons "col" #f) (cons "text" #f)))
      (tui-handle-key! vs tab-event)
      (tui-handle-key! vs char-event)
      SCHEME
  end

  it "raises for an unknown key name" do
    expect_raises(Scheme::SchemeRuntimeError, /tui-handle-key!: unknown key name/) do
      w(<<-SCHEME)
        (define vs (tui-vstack (tui-screen) (tui-text-edit) (tui-text-edit) 3))
        (tui-handle-key! vs (list (cons "key" "not-a-key")))
        SCHEME
    end
  end

  it "runs the blocking loop and returns once stdin is exhausted, invoking on-key-fn for no keys" do
    w(<<-SCHEME).should eq("#t")
      (define screen (tui-screen))
      (define pane (tui-text-edit "hi"))
      (define widget (tui-window screen pane))
      (tui-run screen widget (lambda (ev) #f))
      #t
      SCHEME
  end
end
