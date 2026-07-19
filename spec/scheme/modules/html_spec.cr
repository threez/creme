require "../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme html)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme html)) #{src}")
end

describe "html module" do
  it "renders nested tags with text content" do
    w(%((html->string '(div (p "hi"))))).should eq(%("<div><p>hi</p></div>"))
  end

  it "HTML-escapes text content" do
    w(%q((html->string "<a & b> \"'"))).should eq(%("&lt;a &amp; b&gt; &quot;&#39;"))
  end

  it "renders string, numeric, boolean and omitted attributes" do
    w(%q((html->string '(input (@ (type "text") (maxlength 10) (disabled #t) (readonly #f))))))
      .should eq("\"<input type=\\\"text\\\" maxlength=\\\"10\\\" disabled>\"")
  end

  it "defaults to no attributes when the (@ ...) block is omitted" do
    w(%((html->string '(p "hi")))).should eq(%("<p>hi</p>"))
  end

  it "self-closes void elements and rejects children on them" do
    w(%((html->string '(br)))).should eq(%("<br>"))

    expect_raises(Scheme::SchemeRuntimeError, /void element cannot have children/) do
      run(%((html->string '(br "oops"))))
    end
  end

  it "splices a fragment (a list of nodes) in place, e.g. from map" do
    w(<<-SCHEME).should eq(%("<ul><li>a</li><li>b</li><li>c</li></ul>"))
      (html->string
       (cons 'ul (map (lambda (x) (list 'li x)) '("a" "b" "c"))))
      SCHEME
  end

  it "treats #f and '() as no-op nodes" do
    w(%((html->string (list 'div #f '() "x")))).should eq(%("<div>x</div>"))
  end

  it "writes raw content unescaped" do
    w(%((html->string '(raw "<b>bold</b>")))).should eq(%("<b>bold</b>"))
  end

  it "builds a full document via html-document->string, with and without css" do
    w(%q((html-document->string "Report" "" '(h1 "Hi"))))
      .should eq("\"<!DOCTYPE html><html><head><meta charset=\\\"utf-8\\\"><title>Report</title></head><body><h1>Hi</h1></body></html>\"")

    w(%q((html-document->string "Report" "body { color: red }" '(h1 "Hi"))))
      .should eq("\"<!DOCTYPE html><html><head><meta charset=\\\"utf-8\\\"><title>Report</title><style>body { color: red }</style></head><body><h1>Hi</h1></body></html>\"")
  end

  it "accepts a (creme css) rule list for css, same as a plain string" do
    w(%q((html-document->string "Report" '((body (color "red"))) '(h1 "Hi"))))
      .should eq("\"<!DOCTYPE html><html><head><meta charset=\\\"utf-8\\\"><title>Report</title><style>body {\\n  color: red;\\n}\\n</style></head><body><h1>Hi</h1></body></html>\"")
  end

  it "produces real table markup via html-style, matching the (creme table) style-function protocol" do
    w(%((html-style 'top '() '() '()))).should eq(%("<table>"))
    w(%((html-style 'header-row '("Name" "Age") '() '()))).should eq(%("<tr><th>Name</th><th>Age</th></tr>"))
    w(%((html-style 'row '("Alice" "30") '() '()))).should eq(%("<tr><td>Alice</td><td>30</td></tr>"))
  end

  describe "html! (compile-time template folding)" do
    it "matches html->string for a fully static template" do
      w(%((html! (div (@ (class "x")) (p "hi")))))
        .should eq("\"<div class=\\\"x\\\"><p>hi</p></div>\"")
    end

    it "matches html->string for a single dynamic child" do
      w(<<-SCHEME).should eq(%("<h1>Report</h1>"))
        (define title "Report")
        (html! `(h1 ,title))
        SCHEME
    end

    it "matches html->string for a dynamic attribute" do
      w(<<-SCHEME).should eq("\"<li class=\\\"done\\\">x</li>\"")
        (define done #t)
        (html! `(li (@ (class ,(if done "done" "pending"))) "x"))
        SCHEME
    end

    it "matches html->string for ,@(map ...) fragment splicing" do
      w(<<-SCHEME).should eq(%("<ul><li>a</li><li>b</li></ul>"))
        (html! `(ul ,@(map (lambda (x) `(li ,x)) '("a" "b"))))
        SCHEME
    end

    it "matches html->string for a mix of static and dynamic children" do
      w(<<-SCHEME).should eq(%("<div><h1>Title</h1><p>dyn</p><span>end</span></div>"))
        (define v "dyn")
        (html! `(div (h1 "Title") (p ,v) (span "end")))
        SCHEME
    end

    it "matches html->string for void elements, static and dynamic attrs" do
      w(%((html! (br)))).should eq(%("<br>"))
      w(<<-SCHEME).should eq("\"<input type=\\\"text\\\" disabled>\"")
        (define t "text")
        (html! `(input (@ (type ,t) (disabled #t))))
        SCHEME
    end

    it "matches html->string for raw content" do
      w(%((html! (raw "<b>bold</b>")))).should eq(%("<b>bold</b>"))
    end

    # Dynamic raw content -- (raw ,expr) -- folds to a direct verbatim
    # write (see html-fold's raw branch / html-raw-foldable?), NOT through a
    # runtime quasiquote + html-render. These pin that the fold stays
    # verbatim (no escaping) and preserves argument order.
    it "folds dynamic raw content into a verbatim write (no escaping)" do
      w(<<-SCHEME).should eq(%("<b>bold</b>"))
        (define s "<b>bold</b>")
        (html! `(raw ,s))
        SCHEME
      # the (style (raw ,css)) hot-path shape
      w(<<-SCHEME).should eq(%("<style>.x{color:red}</style>"))
        (define css ".x{color:red}")
        (html! `(style (raw ,css)))
        SCHEME
    end

    it "folds raw with mixed literal and dynamic args, verbatim and in order" do
      w(<<-SCHEME).should eq(%("<i>A</i>"))
        (define mid "A")
        (html! `(raw "<i>" ,mid "</i>"))
        SCHEME
    end

    it "falls back to html-render for unquote-splicing raw args" do
      w(<<-SCHEME).should eq(%("ab"))
        (define parts (list "a" "b"))
        (html! `(raw ,@parts))
        SCHEME
    end

    it "matches html->string for #f/'() no-op nodes" do
      w(%((html! (div #f () "x")))).should eq(%("<div>x</div>"))
    end
  end

  describe "html-write! (folding into an existing port)" do
    it "matches html! for a dynamic attribute, writing into a caller-supplied port" do
      w(<<-SCHEME).should eq("\"<li class=\\\"done\\\">x</li>\"")
        (define done #t)
        (let ((port (open-output-string)))
          (html-write! port `(li (@ (class ,(if done "done" "pending"))) "x"))
          (get-output-string port))
        SCHEME
    end

    it "matches html! for a fully static template" do
      w(%((let ((port (open-output-string)))
            (html-write! port (div (@ (class "x")) (p "hi")))
            (get-output-string port))))
        .should eq("\"<div class=\\\"x\\\"><p>hi</p></div>\"")
    end
  end

  describe "html-document-write! (writing a full document into an existing port)" do
    it "matches html-document->string" do
      w(%((let ((port (open-output-string)))
            (html-document-write! port "Report" "body { color: red }" '(h1 "Hi"))
            (get-output-string port))))
        .should eq("\"<!DOCTYPE html><html><head><meta charset=\\\"utf-8\\\"><title>Report</title><style>body { color: red }</style></head><body><h1>Hi</h1></body></html>\"")
    end
  end
end
