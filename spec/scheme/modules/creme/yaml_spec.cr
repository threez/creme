require "../../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme yaml)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme yaml)) #{src}")
end

describe "yaml module" do
  it "reads a bare scalar" do
    w(%((yaml-read "42"))).should eq("42")
  end

  it "reads a sequence into a vector" do
    w("(yaml-read \"- 1\\n- 2\\n- 3\\n\")").should eq("#(1 2 3)")
  end

  it "reads a mapping into an alist" do
    w("(yaml-read \"a: 1\\nb: two\\nc: true\\n\")").should eq(%((("a" . 1) ("b" . "two") ("c" . #t))))
  end

  it "conflates an empty mapping with null" do
    w(%((yaml-read "{}"))).should eq("()")
    w(%((yaml-read "null"))).should eq("()")
  end

  it "resolves core-schema plain scalars: bool words, null words, hex/octal/underscored ints" do
    w("(yaml-read \"a: yes\\nb: no\\nc: on\\nd: off\\n\")").should eq(%((("a" . #t) ("b" . #f) ("c" . #t) ("d" . #f))))
    w("(yaml-read \"a: 0x1F\\nb: 0o17\\nc: 010\\nd: 1_000\\n\")").should eq(%((("a" . 31) ("b" . 15) ("c" . 8) ("d" . 1000))))
  end

  it "keeps a quoted scalar a string even if it looks like a bool/int" do
    w("(yaml-read \"a: \\\"true\\\"\\nb: '123'\\n\")").should eq(%((("a" . "true") ("b" . "123"))))
  end

  it "raises on malformed yaml" do
    expect_raises(Scheme::SchemeError) { run(%((yaml-read "a: [1,2"))) }
  end

  it "round-trips a vector through yaml-write/yaml-read" do
    w(%((yaml-read (yaml-write (vector 1 2 "three"))))).should eq(%(#(1 2 "three")))
  end

  it "round-trips a (string . value) alist as a mapping" do
    w(%((yaml-read (yaml-write (list (cons "a" 1) (cons "b" (vector 1 2))))))).should eq(%((("a" . 1) ("b" . #(1 2)))))
  end

  it "writes a plain (non-alist) proper list as a sequence" do
    w(%((yaml-write (list 1 2 3)))).should eq(%("---\\n- 1\\n- 2\\n- 3\\n"))
  end

  it "raises writing an improper list" do
    expect_raises(Scheme::SchemeError) { run(%((yaml-write (cons 1 2)))) }
  end
end
