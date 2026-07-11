require "../spec_helper"

describe LISP::Reader do
  it "reads atoms" do
    forms = LISP::Reader.read_all("42 3.14 \"hi\" sym #t #f")
    forms[0].as(LISP::LispInt).value.should eq(42_i64)
    forms[1].as(LISP::LispFloat).value.should eq(3.14)
    forms[2].as(LISP::LispStr).value.should eq("hi")
    forms[3].as(LISP::LispSym).name.should eq("sym")
    forms[4].should be(LISP::TRUE)
    forms[5].should be(LISP::FALSE)
  end

  it "reads a char literal" do
    forms = LISP::Reader.read_all(%(#\\a))
    forms[0].as(LISP::LispChar).value.should eq('a')
  end

  it "reads nested lists" do
    forms = LISP::Reader.read_all("(1 (2 3) 4)")
    forms[0].write_string.should eq("(1 (2 3) 4)")
  end

  it "reads dotted pairs" do
    forms = LISP::Reader.read_all("(a . b)")
    forms[0].write_string.should eq("(a . b)")
  end

  it "reads an improper list with more than one leading element" do
    forms = LISP::Reader.read_all("(1 2 . 3)")
    forms[0].write_string.should eq("(1 2 . 3)")
  end

  it "expands quote sugar" do
    LISP::Reader.read_all("'x")[0].write_string.should eq("(quote x)")
  end

  it "expands quasiquote sugar" do
    LISP::Reader.read_all("`x")[0].write_string.should eq("(quasiquote x)")
  end

  it "expands unquote sugar" do
    LISP::Reader.read_all(",x")[0].write_string.should eq("(unquote x)")
  end

  it "expands unquote-splicing sugar" do
    LISP::Reader.read_all(",@x")[0].write_string.should eq("(unquote-splicing x)")
  end

  it "reads an empty list as nil" do
    LISP::Reader.read_all("()")[0].should be(LISP::NIL)
  end

  it "reads multiple top-level forms" do
    LISP::Reader.read_all("1 2 3").size.should eq(3)
  end

  it "reads empty input as no forms" do
    LISP::Reader.read_all("").should be_empty
  end

  it "raises LispParseError on deeply nested input beyond MAX_DEPTH" do
    src = ("(" * (LISP::Reader::MAX_DEPTH + 10)) + "1" + (")" * (LISP::Reader::MAX_DEPTH + 10))
    expect_raises(LISP::LispParseError, /nesting too deep/) do
      LISP::Reader.read_all(src)
    end
  end

  it "raises LispIncompleteError on EOF mid-list" do
    expect_raises(LISP::LispIncompleteError) do
      LISP::Reader.read_all("(1 2")
    end
  end

  it "raises LispIncompleteError on EOF right after a quote" do
    expect_raises(LISP::LispIncompleteError) do
      LISP::Reader.read_all("'")
    end
  end

  it "raises LispIncompleteError on EOF right after a dot" do
    expect_raises(LISP::LispIncompleteError) do
      LISP::Reader.read_all("(a .")
    end
  end

  it "raises LispIncompleteError on EOF right after the dotted tail (unbalanced paren)" do
    expect_raises(LISP::LispIncompleteError) do
      LISP::Reader.read_all("(a . b")
    end
  end

  it "raises LispParseError on an unexpected ')'" do
    expect_raises(LISP::LispParseError, /unexpected '\)'/) do
      LISP::Reader.read_all(")")
    end
  end

  it "raises LispParseError on a stray '.' at top level" do
    expect_raises(LISP::LispParseError, /unexpected '\.'/) do
      LISP::Reader.read_all(".")
    end
  end

  it "raises LispParseError when a dotted tail isn't followed by ')'" do
    expect_raises(LISP::LispParseError, /expected '\)' after dotted tail/) do
      LISP::Reader.read_all("(a . b c)")
    end
  end

  it "reads a vector literal" do
    forms = LISP::Reader.read_all("#(1 2 3)")
    vec = forms[0].as(LISP::LispVector)
    vec.value.map(&.as(LISP::LispInt).value).should eq([1_i64, 2_i64, 3_i64])
  end

  it "reads an empty vector literal" do
    forms = LISP::Reader.read_all("#()")
    forms[0].as(LISP::LispVector).value.should be_empty
  end

  it "reads nested vector literals" do
    forms = LISP::Reader.read_all("#(1 #(2 3))")
    outer = forms[0].as(LISP::LispVector)
    outer.value[0].as(LISP::LispInt).value.should eq(1_i64)
    inner = outer.value[1].as(LISP::LispVector)
    inner.value.map(&.as(LISP::LispInt).value).should eq([2_i64, 3_i64])
  end

  it "raises LispParseError on a stray '.' inside a vector literal" do
    expect_raises(LISP::LispParseError, /unexpected '\.' inside vector literal/) do
      LISP::Reader.read_all("#(1 . 2)")
    end
  end

  it "raises LispIncompleteError on an unbalanced vector literal" do
    expect_raises(LISP::LispIncompleteError) do
      LISP::Reader.read_all("#(1 2")
    end
  end
end
