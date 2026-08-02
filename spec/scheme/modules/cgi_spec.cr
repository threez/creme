require "../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (creme cgi)) #{src}").write_string
end

describe "cgi module" do
  it "escapes unsafe characters and spaces" do
    w(%((cgi-escape "Hello World!"))).should eq(%("Hello+World%21"))
  end

  it "leaves alnum and safe punctuation untouched" do
    w(%((cgi-escape "abc_123.-XYZ"))).should eq(%("abc_123.-XYZ"))
  end

  it "escapes non-ASCII text via its UTF-8 bytes" do
    w(%((cgi-escape "café"))).should eq(%("caf%C3%A9"))
  end

  it "unescapes + back to space and %XX back to a byte" do
    w(%((cgi-unescape "Hello+World%21"))).should eq(%("Hello World!"))
  end

  it "round-trips non-ASCII text through escape/unescape" do
    w(%((cgi-unescape (cgi-escape "café")))).should eq(%("café"))
  end

  it "escapes HTML entities via (creme html)'s html-escape" do
    w("(cgi-escape-html \"<a href=\\\"x\\\">'y'</a>\")")
      .should eq(%("&lt;a href=&quot;x&quot;&gt;&#39;y&#39;&lt;/a&gt;"))
  end

  it "unescapes the 5 basic named entities" do
    w(%((cgi-unescape-html "&lt;a href=&quot;x&quot;&gt;&#39;y&#39;&lt;/a&gt;")))
      .should eq("\"<a href=\\\"x\\\">'y'</a>\"")
  end

  it "unescapes numeric decimal and hex character references" do
    w(%((cgi-unescape-html "&#65;&#x42;"))).should eq(%("AB"))
  end

  it "leaves an unrecognized entity and a bare & unchanged" do
    w(%((cgi-unescape-html "&yen; & tom"))).should eq(%("&yen; & tom"))
  end

  it "parses a simple query string" do
    w(%((cgi-parse "a=1&b=2"))).should eq(%((("a" "1") ("b" "2"))))
  end

  it "accumulates repeated keys instead of last-wins" do
    w(%((cgi-parse "a=1&a=2&b=3"))).should eq(%((("a" "1" "2") ("b" "3"))))
  end

  it "maps a key with no = to a single empty-string value" do
    w(%((cgi-parse "a"))).should eq(%((("a" ""))))
  end

  it "unescapes keys and values while parsing" do
    w(%((cgi-parse "na%20me=Jo+Bloggs"))).should eq(%((("na me" "Jo Bloggs"))))
  end

  it "returns an empty alist for an empty query string" do
    w(%((cgi-parse ""))).should eq("()")
  end
end
