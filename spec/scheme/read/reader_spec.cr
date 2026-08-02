require "../../spec_helper"

describe Creme::Reader do
  it "reads atoms" do
    forms = Creme::Reader.read_all("42 3.14 \"hi\" sym #t #f")
    forms[0].as(Creme::SchemeInt).value.should eq(42_i64)
    forms[1].as(Creme::SchemeFloat).value.should eq(3.14)
    forms[2].as(Creme::SchemeStr).value.should eq("hi")
    forms[3].as(Creme::SchemeSym).name.should eq("sym")
    forms[4].should eq(Creme::TRUE)
    forms[5].should eq(Creme::FALSE)
  end

  it "reads a char literal" do
    forms = Creme::Reader.read_all(%(#\\a))
    forms[0].as(Creme::SchemeChar).value.should eq('a')
  end

  it "reads nested lists" do
    forms = Creme::Reader.read_all("(1 (2 3) 4)")
    forms[0].write_string.should eq("(1 (2 3) 4)")
  end

  it "reads dotted pairs" do
    forms = Creme::Reader.read_all("(a . b)")
    forms[0].write_string.should eq("(a . b)")
  end

  it "reads an improper list with more than one leading element" do
    forms = Creme::Reader.read_all("(1 2 . 3)")
    forms[0].write_string.should eq("(1 2 . 3)")
  end

  it "expands quote sugar" do
    Creme::Reader.read_all("'x")[0].write_string.should eq("(quote x)")
  end

  it "expands quasiquote sugar" do
    Creme::Reader.read_all("`x")[0].write_string.should eq("(quasiquote x)")
  end

  it "expands unquote sugar" do
    Creme::Reader.read_all(",x")[0].write_string.should eq("(unquote x)")
  end

  it "expands unquote-splicing sugar" do
    Creme::Reader.read_all(",@x")[0].write_string.should eq("(unquote-splicing x)")
  end

  it "reads an empty list as nil" do
    Creme::Reader.read_all("()")[0].should eq(Creme::NIL)
  end

  it "reads multiple top-level forms" do
    Creme::Reader.read_all("1 2 3").size.should eq(3)
  end

  it "reads empty input as no forms" do
    Creme::Reader.read_all("").should be_empty
  end

  it "raises SchemeParseError on deeply nested input beyond MAX_DEPTH" do
    src = ("(" * (Creme::Reader::MAX_DEPTH + 10)) + "1" + (")" * (Creme::Reader::MAX_DEPTH + 10))
    expect_raises(Creme::SchemeParseError, /nesting too deep/) do
      Creme::Reader.read_all(src)
    end
  end

  it "raises SchemeIncompleteError on EOF mid-list" do
    expect_raises(Creme::SchemeIncompleteError) do
      Creme::Reader.read_all("(1 2")
    end
  end

  it "raises SchemeIncompleteError on EOF right after a quote" do
    expect_raises(Creme::SchemeIncompleteError) do
      Creme::Reader.read_all("'")
    end
  end

  it "raises SchemeIncompleteError on EOF right after a dot" do
    expect_raises(Creme::SchemeIncompleteError) do
      Creme::Reader.read_all("(a .")
    end
  end

  it "raises SchemeIncompleteError on EOF right after the dotted tail (unbalanced paren)" do
    expect_raises(Creme::SchemeIncompleteError) do
      Creme::Reader.read_all("(a . b")
    end
  end

  it "raises SchemeParseError on an unexpected ')'" do
    expect_raises(Creme::SchemeParseError, /unexpected '\)'/) do
      Creme::Reader.read_all(")")
    end
  end

  it "raises SchemeParseError on a stray '.' at top level" do
    expect_raises(Creme::SchemeParseError, /unexpected '\.'/) do
      Creme::Reader.read_all(".")
    end
  end

  it "raises SchemeParseError when a dotted tail isn't followed by ')'" do
    expect_raises(Creme::SchemeParseError, /expected '\)' after dotted tail/) do
      Creme::Reader.read_all("(a . b c)")
    end
  end

  it "reads a vector literal" do
    forms = Creme::Reader.read_all("#(1 2 3)")
    vec = forms[0].as(Creme::SchemeVector)
    vec.value.map(&.as(Creme::SchemeInt).value).should eq([1_i64, 2_i64, 3_i64])
  end

  it "reads an empty vector literal" do
    forms = Creme::Reader.read_all("#()")
    forms[0].as(Creme::SchemeVector).value.should be_empty
  end

  it "reads nested vector literals" do
    forms = Creme::Reader.read_all("#(1 #(2 3))")
    outer = forms[0].as(Creme::SchemeVector)
    outer.value[0].as(Creme::SchemeInt).value.should eq(1_i64)
    inner = outer.value[1].as(Creme::SchemeVector)
    inner.value.map(&.as(Creme::SchemeInt).value).should eq([2_i64, 3_i64])
  end

  it "raises SchemeParseError on a stray '.' inside a vector literal" do
    expect_raises(Creme::SchemeParseError, /unexpected '\.' inside vector literal/) do
      Creme::Reader.read_all("#(1 . 2)")
    end
  end

  it "raises SchemeIncompleteError on an unbalanced vector literal" do
    expect_raises(Creme::SchemeIncompleteError) do
      Creme::Reader.read_all("#(1 2")
    end
  end

  it "reads a bytevector literal" do
    forms = Creme::Reader.read_all("#u8(1 2 3)")
    forms[0].as(Creme::SchemeBlob).value.should eq(Bytes[1, 2, 3])
  end

  it "reads an empty bytevector literal" do
    forms = Creme::Reader.read_all("#u8()")
    forms[0].as(Creme::SchemeBlob).value.should be_empty
  end

  it "reads a bytevector literal with byte values at the 0/255 boundary" do
    forms = Creme::Reader.read_all("#u8(0 255)")
    forms[0].as(Creme::SchemeBlob).value.should eq(Bytes[0, 255])
  end

  it "raises SchemeParseError for an out-of-range byte value in a bytevector literal" do
    expect_raises(Creme::SchemeParseError, /out of range/) { Creme::Reader.read_all("#u8(256)") }
    expect_raises(Creme::SchemeParseError, /out of range/) { Creme::Reader.read_all("#u8(-1)") }
  end

  it "raises SchemeParseError for a non-integer element in a bytevector literal" do
    expect_raises(Creme::SchemeParseError, /must be integers/) { Creme::Reader.read_all("#u8(1.5)") }
  end

  it "raises SchemeParseError on a stray '.' inside a bytevector literal" do
    expect_raises(Creme::SchemeParseError, /unexpected '\.' inside bytevector literal/) do
      Creme::Reader.read_all("#u8(1 . 2)")
    end
  end

  it "raises SchemeIncompleteError on an unbalanced bytevector literal" do
    expect_raises(Creme::SchemeIncompleteError) do
      Creme::Reader.read_all("#u8(1 2")
    end
  end

  it "reads a complex literal with both real and imaginary parts" do
    c = Creme::Reader.read_all("3+4i")[0].as(Creme::SchemeComplex)
    c.real.as(Creme::SchemeInt).value.should eq(3_i64)
    c.imag.as(Creme::SchemeInt).value.should eq(4_i64)
  end

  it "reads a complex literal with a negative imaginary part" do
    c = Creme::Reader.read_all("3-4i")[0].as(Creme::SchemeComplex)
    c.real.as(Creme::SchemeInt).value.should eq(3_i64)
    c.imag.as(Creme::SchemeInt).value.should eq(-4_i64)
  end

  it "reads a pure-imaginary literal with no real part" do
    c = Creme::Reader.read_all("2i")[0].as(Creme::SchemeComplex)
    c.real.as(Creme::SchemeInt).value.should eq(0_i64)
    c.imag.as(Creme::SchemeInt).value.should eq(2_i64)
  end

  it "reads a negative pure-imaginary literal" do
    c = Creme::Reader.read_all("-2i")[0].as(Creme::SchemeComplex)
    c.imag.as(Creme::SchemeInt).value.should eq(-2_i64)
  end

  it "reads +i and -i as unit imaginary magnitude" do
    plus_i = Creme::Reader.read_all("+i")[0].as(Creme::SchemeComplex)
    plus_i.imag.as(Creme::SchemeInt).value.should eq(1_i64)
    minus_i = Creme::Reader.read_all("-i")[0].as(Creme::SchemeComplex)
    minus_i.imag.as(Creme::SchemeInt).value.should eq(-1_i64)
  end

  it "reads float real/imaginary components" do
    c = Creme::Reader.read_all("1.5+0.5i")[0].as(Creme::SchemeComplex)
    c.real.as(Creme::SchemeFloat).value.should eq(1.5)
    c.imag.as(Creme::SchemeFloat).value.should eq(0.5)
  end

  it "does not misinterpret a float exponent sign as the real/imag separator" do
    c = Creme::Reader.read_all("1e10+2i")[0].as(Creme::SchemeComplex)
    c.real.as(Creme::SchemeFloat).value.should eq(1e10)
    c.imag.as(Creme::SchemeInt).value.should eq(2_i64)
  end

  it "collapses a complex literal with an exact zero imaginary part to a plain real" do
    Creme::Reader.read_all("3+0i")[0].should be_a(Creme::SchemeInt)
  end

  describe "#; datum comments" do
    it "skips a leading datum" do
      forms = Creme::Reader.read_all("#;1 2")
      forms.size.should eq(1)
      forms[0].as(Creme::SchemeInt).value.should eq(2_i64)
    end

    it "skips a datum in the middle of a list" do
      forms = Creme::Reader.read_all("(1 #;2 3)")
      forms[0].write_string.should eq("(1 3)")
    end

    it "skips a whole compound (nested) datum as one unit" do
      forms = Creme::Reader.read_all("(1 #;(a (b c) d) 2)")
      forms[0].write_string.should eq("(1 2)")
    end

    it "handles consecutive datum comments" do
      forms = Creme::Reader.read_all("#; #; a b c")
      forms.size.should eq(1)
      forms[0].as(Creme::SchemeSym).name.should eq("c")
    end

    it "handles a datum comment as an entire top-level form" do
      forms = Creme::Reader.read_all("#;(this is discarded) 5")
      forms.size.should eq(1)
      forms[0].as(Creme::SchemeInt).value.should eq(5_i64)
    end
  end

  describe "#| ... |# block comments" do
    it "is invisible to the reader, same as whitespace" do
      forms = Creme::Reader.read_all("#| comment |# (1 2 3)")
      forms.size.should eq(1)
      forms[0].write_string.should eq("(1 2 3)")
    end

    it "nests" do
      forms = Creme::Reader.read_all("#| outer #| inner |# still outer |# 42")
      forms[0].as(Creme::SchemeInt).value.should eq(42_i64)
    end

    it "interleaves correctly with real code and other comment kinds" do
      src = <<-SCM
        ; line comment
        #| block comment |#
        (display 1) ; trailing line comment
        #;(display 2)
        (display 3)
        SCM
      forms = Creme::Reader.read_all(src)
      forms.size.should eq(2)
    end
  end
end
