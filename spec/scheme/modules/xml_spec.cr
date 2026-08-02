require "../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (scheme base) (creme xml)) #{src}").write_string
end

describe "xml module" do
  it "parses a simple element with text content" do
    w(%((xml-read "<a>hi</a>"))).should eq(%((a "hi")))
  end

  it "parses attributes into (@ (name value) ...)" do
    w("(xml-read \"<a href=\\\"x\\\" id='y'>hi</a>\")")
      .should eq(%((a (@ (href "x") (id "y")) "hi")))
  end

  it "parses nested elements" do
    w(%((xml-read "<a><b>1</b><c>2</c></a>"))).should eq(%((a (b "1") (c "2"))))
  end

  it "parses a self-closing element with no children" do
    w(%((xml-read "<br/>"))).should eq("(br)")
  end

  it "decodes entities in text and attribute values" do
    w("(xml-read \"<a x=\\\"1 &amp; 2\\\">&lt;tag&gt;</a>\")")
      .should eq(%((a (@ (x "1 & 2")) "<tag>")))
  end

  it "skips comments and processing instructions" do
    w("(xml-read \"<?xml version=\\\"1.0\\\"?><!-- a comment --><a>hi</a>\")")
      .should eq(%((a "hi")))
  end

  it "skips a DOCTYPE declaration" do
    w(%((xml-read "<!DOCTYPE html><a>hi</a>"))).should eq(%((a "hi")))
  end

  it "raises on a mismatched closing tag" do
    interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
    expect_raises(Scheme::SchemeError) do
      Scheme.run_source(interp, "(import (scheme base) (creme xml)) (xml-read \"<a>1</b>\")")
    end
  end

  it "round-trips through xml-write/xml->string" do
    w("(xml->string (xml-read \"<a href=\\\"x\\\"><b>1</b><c>2</c></a>\"))")
      .should eq("\"<a href=\\\"x\\\"><b>1</b><c>2</c></a>\"")
  end

  it "self-closes an element with no children when writing" do
    w(%((xml->string '(br)))).should eq(%("<br/>"))
  end

  it "escapes text and attribute values when writing" do
    w(%((xml->string (list 'a (list '@ (list 'x "1 & 2")) "<tag>"))))
      .should eq("\"<a x=\\\"1 &amp; 2\\\">&lt;tag&gt;</a>\"")
  end
end
