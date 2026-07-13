require "../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, "(import (creme format)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, "(import (creme format)) #{src}")
end

describe "format module" do
  it "renders ~a, ~s, ~% and ~~" do
    w(%((format #f "hi ~a and ~s~%" "world" "quoted"))).should eq("\"hi world and \\\"quoted\\\"\\n\"")
    w(%((format #f "literal ~~"))).should eq(%("literal ~"))
  end

  it "renders numeric radix directives" do
    w(%((format #f "~d ~x ~o ~b" 42 255 8 5))).should eq(%("42 ff 10 101"))
  end

  it "renders a char with ~c" do
    w(%((format #f "~c" #\\z))).should eq(%("z"))
  end

  it "format dispatches on #f vs #t destination" do
    w(%((format #f "~a" 42))).should eq(%("42"))
    run(%((format #t "~a" 42))).write_string.should eq("()")
  end

  it "raises on unknown directives and missing arguments" do
    expect_raises(Scheme::SchemeRuntimeError, /unknown format directive/) do
      run(%((format #f "~q")))
    end
    expect_raises(Scheme::SchemeRuntimeError, /not enough arguments/) do
      run(%((format #f "~a")))
    end
    expect_raises(Scheme::SchemeRuntimeError, /expected #t or #f as destination/) do
      run(%((format 5 "~a" 1)))
    end
  end
end
