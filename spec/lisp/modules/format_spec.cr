require "../../spec_helper"

private def w(src : String) : String
  interp = LISP::Interpreter.new
  LISP.run_source(interp, "(require 'format) #{src}").write_string
end

private def run(src : String) : LISP::LispValue
  interp = LISP::Interpreter.new
  LISP.run_source(interp, "(require 'format) #{src}")
end

describe "format module" do
  it "renders ~a, ~s, ~% and ~~" do
    w(%((format:sprintf "hi ~a and ~s~%" "world" "quoted"))).should eq("\"hi world and \\\"quoted\\\"\\n\"")
    w(%((format:sprintf "literal ~~"))).should eq(%("literal ~"))
  end

  it "renders numeric radix directives" do
    w(%((format:sprintf "~d ~x ~o ~b" 42 255 8 5))).should eq(%("42 ff 10 101"))
  end

  it "renders a char with ~c" do
    w(%((format:sprintf "~c" #\\z))).should eq(%("z"))
  end

  it "sprintf returns a string, printf writes to stdout" do
    w(%((format:sprintf "~a" 1))).should eq(%("1"))
    run(%((format:printf "~a" 1))).write_string.should eq("()")
  end

  it "format dispatches on #f vs #t destination" do
    w(%((format:format #f "~a" 42))).should eq(%("42"))
    run(%((format:format #t "~a" 42))).write_string.should eq("()")
  end

  it "raises on unknown directives and missing arguments" do
    expect_raises(LISP::LispRuntimeError, /unknown format directive/) do
      run(%((format:sprintf "~q")))
    end
    expect_raises(LISP::LispRuntimeError, /not enough arguments/) do
      run(%((format:sprintf "~a")))
    end
    expect_raises(LISP::LispRuntimeError, /expected #t or #f as destination/) do
      run(%((format:format 5 "~a" 1)))
    end
  end
end
