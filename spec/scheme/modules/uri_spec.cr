require "../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (creme uri)) #{src}").write_string
end

describe "uri module" do
  it "parses scheme/host/port/path/query/fragment" do
    w(<<-SCHEME).should eq(%(("https" "example.com" 8080 "/a/b" "q=1" "frag")))
      (define u (uri-parse "https://example.com:8080/a/b?q=1#frag"))
      (list (uri-scheme u) (uri-host u) (uri-port u) (uri-path u) (uri-query u) (uri-fragment u))
      SCHEME
  end

  it "parses userinfo" do
    w(%((uri-userinfo (uri-parse "ftp://user:pass@host/path")))).should eq(%("user:pass"))
  end

  it "leaves port #f when absent" do
    w(%((uri-port (uri-parse "http://example.com/path")))).should eq("#f")
  end

  it "distinguishes an absent authority (host #f) from an empty one" do
    w(%((uri-host (uri-parse "mailto:foo@bar.com")))).should eq("#f")
    w(%((uri-host (uri-parse "file:///etc/hosts")))).should eq(%(""))
  end

  it "round-trips a full URI through uri->string" do
    w(%((uri->string (uri-parse "https://user@example.com:8080/a/b?q=1#frag"))))
      .should eq(%("https://user@example.com:8080/a/b?q=1#frag"))
  end

  it "encodes an alist as a www-form query string" do
    w(%((uri-encode-www-form (list (cons "a" "1") (cons "b c" "2"))))).should eq(%("a=1&b+c=2"))
  end

  it "decodes a query string into one pair per occurrence, not grouped" do
    w(%((uri-decode-www-form "a=1&a=2&b=3")))
      .should eq(%((("a" . "1") ("a" . "2") ("b" . "3"))))
  end

  describe "uri-join (RFC 3986 5.4 normal examples, base http://a/b/c/d;p?q)" do
    it "resolves simple relative references" do
      w(<<-SCHEME).should eq(%("http://a/b/c/g"))
        (uri->string (uri-join (uri-parse "http://a/b/c/d;p?q") "g"))
        SCHEME
      w(<<-SCHEME).should eq(%("http://a/b/c/g"))
        (uri->string (uri-join (uri-parse "http://a/b/c/d;p?q") "./g"))
        SCHEME
      w(<<-SCHEME).should eq(%("http://a/b/c/g/"))
        (uri->string (uri-join (uri-parse "http://a/b/c/d;p?q") "g/"))
        SCHEME
    end

    it "resolves an absolute-path reference against a different scheme/host" do
      w(<<-SCHEME).should eq(%("http://a/g"))
        (uri->string (uri-join (uri-parse "http://a/b/c/d;p?q") "/g"))
        SCHEME
      w(<<-SCHEME).should eq(%("http://g"))
        (uri->string (uri-join (uri-parse "http://a/b/c/d;p?q") "//g"))
        SCHEME
    end

    it "resolves a query-only or fragment-only reference against the same path" do
      w(<<-SCHEME).should eq(%("http://a/b/c/d;p?y"))
        (uri->string (uri-join (uri-parse "http://a/b/c/d;p?q") "?y"))
        SCHEME
      w(<<-SCHEME).should eq(%("http://a/b/c/d;p?q#s"))
        (uri->string (uri-join (uri-parse "http://a/b/c/d;p?q") "#s"))
        SCHEME
    end

    it "resolves an empty reference to the exact same URI" do
      w(<<-SCHEME).should eq(%("http://a/b/c/d;p?q"))
        (uri->string (uri-join (uri-parse "http://a/b/c/d;p?q") ""))
        SCHEME
    end

    it "resolves dot-segment references" do
      w(<<-SCHEME).should eq(%("http://a/b/c/"))
        (uri->string (uri-join (uri-parse "http://a/b/c/d;p?q") "."))
        SCHEME
      w(<<-SCHEME).should eq(%("http://a/b/"))
        (uri->string (uri-join (uri-parse "http://a/b/c/d;p?q") ".."))
        SCHEME
      w(<<-SCHEME).should eq(%("http://a/b/g"))
        (uri->string (uri-join (uri-parse "http://a/b/c/d;p?q") "../g"))
        SCHEME
      w(<<-SCHEME).should eq(%("http://a/"))
        (uri->string (uri-join (uri-parse "http://a/b/c/d;p?q") "../.."))
        SCHEME
      w(<<-SCHEME).should eq(%("http://a/g"))
        (uri->string (uri-join (uri-parse "http://a/b/c/d;p?q") "../../g"))
        SCHEME
    end

    it "clamps excess .. beyond root instead of erroring (abnormal example)" do
      w(<<-SCHEME).should eq(%("http://a/g"))
        (uri->string (uri-join (uri-parse "http://a/b/c/d;p?q") "../../../g"))
        SCHEME
      w(<<-SCHEME).should eq(%("http://a/g"))
        (uri->string (uri-join (uri-parse "http://a/b/c/d;p?q") "/./g"))
        SCHEME
      w(<<-SCHEME).should eq(%("http://a/g"))
        (uri->string (uri-join (uri-parse "http://a/b/c/d;p?q") "/../g"))
        SCHEME
    end

    it "keeps a scheme-qualified reference untouched but for dot-segment removal" do
      w(<<-SCHEME).should eq(%("g:h"))
        (uri->string (uri-join (uri-parse "http://a/b/c/d;p?q") "g:h"))
        SCHEME
    end
  end
end
