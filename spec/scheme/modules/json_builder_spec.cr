require "../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme json-builder)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme json-builder)) #{src}")
end

describe "json-builder module" do
  describe "scalars" do
    it "renders a plain string" do
      w(%((json->string "hi"))).should eq("\"\\\"hi\\\"\"")
    end

    it "escapes an embedded quote" do
      w(%q((json->string "a \"quote\""))).should eq("\"\\\"a \\\\\\\"quote\\\\\\\"\\\"\"")
    end

    it "escapes an embedded backslash" do
      w(%q((json->string "back\\slash"))).should eq("\"\\\"back\\\\\\\\slash\\\"\"")
    end

    it "escapes a newline" do
      w(%q((json->string (string #\newline)))).should eq("\"\\\"\\\\n\\\"\"")
    end

    it "escapes a control character via \\u00XX" do
      w(%q((json->string (string (integer->char 1))))).should eq("\"\\\"\\\\u0001\\\"\"")
    end

    it "renders numbers" do
      w(%((json->string 42))).should eq("\"42\"")
      w(%((json->string 3.5))).should eq("\"3.5\"")
    end

    it "renders booleans and null" do
      w(%((json->string #t))).should eq("\"true\"")
      w(%((json->string #f))).should eq("\"false\"")
      w(%((json->string 'null))).should eq("\"null\"")
    end

    it "errors on a value with no valid JSON number syntax" do
      expect_raises(Scheme::SchemeRuntimeError) do
        run(%((json->string 1/2)))
      end
    end
  end

  it "renders (object ...) with symbol or string keys" do
    w(%((json->string '(object (a 1) (b 2))))).should eq("\"{\\\"a\\\":1,\\\"b\\\":2}\"")
    w(%((json->string '(object ("a" 1))))).should eq("\"{\\\"a\\\":1}\"")
  end

  it "renders (array ...)" do
    w(%((json->string '(array 1 2 3)))).should eq(%("[1,2,3]"))
    w(%((json->string '(array)))).should eq(%("[]"))
  end

  it "nests objects and arrays" do
    w(%((json->string '(object (id 1) (tags (array "a" "b"))))))
      .should eq("\"{\\\"id\\\":1,\\\"tags\\\":[\\\"a\\\",\\\"b\\\"]}\"")
  end

  it "(raw ...) embeds a string verbatim, unescaped and unquoted" do
    w(%((json->string '(raw "1,2,3")))).should eq(%("1,2,3"))
    w(%((json->string (list 'array (list 'raw "1,2,3"))))).should eq(%("[1,2,3]"))
  end

  describe "json!" do
    it "folds a fully-static template to one string literal" do
      w(%((json! (object (a 1) (b (array 1 2 3)))))).should eq("\"{\\\"a\\\":1,\\\"b\\\":[1,2,3]}\"")
    end

    it "renders a dynamic seam at runtime" do
      w(<<-SCM).should eq("\"{\\\"id\\\":1,\\\"title\\\":\\\"hi\\\"}\"")
        (define title "hi")
        (json! `(object (id 1) (title ,title)))
        SCM
    end
  end

  it "json-write! streams into an already-open port" do
    w(<<-SCM).should eq(%("[1,2,3]"))
      (define port (open-output-string))
      (json-write! port `(array 1 2 ,(+ 1 2)))
      (get-output-string port)
      SCM
  end

  describe "json-array-write!" do
    it "writes each element via proc, comma-separated, into an already-open port" do
      w(<<-SCM).should eq(%("[1,4,9]"))
        (define port (open-output-string))
        (json-array-write! port
          (lambda (port n) (json-write! port `(raw ,(number->string (* n n)))))
          '(1 2 3))
        (get-output-string port)
        SCM
    end

    it "writes [] for an empty list" do
      w(<<-SCM).should eq(%("[]"))
        (define port (open-output-string))
        (json-array-write! port (lambda (port n) (json-write! port `,n)) '())
        (get-output-string port)
        SCM
    end
  end
end
