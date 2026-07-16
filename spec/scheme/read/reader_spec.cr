require "../../spec_helper"

describe Scheme::Reader do
  it "reads atoms" do
    forms = Scheme::Reader.read_all("42 3.14 \"hi\" sym #t #f")
    forms[0].as(Scheme::SchemeInt).value.should eq(42_i64)
    forms[1].as(Scheme::SchemeFloat).value.should eq(3.14)
    forms[2].as(Scheme::SchemeStr).value.should eq("hi")
    forms[3].as(Scheme::SchemeSym).name.should eq("sym")
    forms[4].should eq(Scheme::TRUE)
    forms[5].should eq(Scheme::FALSE)
  end

  it "reads a char literal" do
    forms = Scheme::Reader.read_all(%(#\\a))
    forms[0].as(Scheme::SchemeChar).value.should eq('a')
  end

  it "reads nested lists" do
    forms = Scheme::Reader.read_all("(1 (2 3) 4)")
    forms[0].write_string.should eq("(1 (2 3) 4)")
  end

  it "reads dotted pairs" do
    forms = Scheme::Reader.read_all("(a . b)")
    forms[0].write_string.should eq("(a . b)")
  end

  it "reads an improper list with more than one leading element" do
    forms = Scheme::Reader.read_all("(1 2 . 3)")
    forms[0].write_string.should eq("(1 2 . 3)")
  end

  it "expands quote sugar" do
    Scheme::Reader.read_all("'x")[0].write_string.should eq("(quote x)")
  end

  it "expands quasiquote sugar" do
    Scheme::Reader.read_all("`x")[0].write_string.should eq("(quasiquote x)")
  end

  it "expands unquote sugar" do
    Scheme::Reader.read_all(",x")[0].write_string.should eq("(unquote x)")
  end

  it "expands unquote-splicing sugar" do
    Scheme::Reader.read_all(",@x")[0].write_string.should eq("(unquote-splicing x)")
  end

  it "reads an empty list as nil" do
    Scheme::Reader.read_all("()")[0].should eq(Scheme::NIL)
  end

  it "reads multiple top-level forms" do
    Scheme::Reader.read_all("1 2 3").size.should eq(3)
  end

  it "reads empty input as no forms" do
    Scheme::Reader.read_all("").should be_empty
  end

  it "raises SchemeParseError on deeply nested input beyond MAX_DEPTH" do
    src = ("(" * (Scheme::Reader::MAX_DEPTH + 10)) + "1" + (")" * (Scheme::Reader::MAX_DEPTH + 10))
    expect_raises(Scheme::SchemeParseError, /nesting too deep/) do
      Scheme::Reader.read_all(src)
    end
  end

  it "raises SchemeIncompleteError on EOF mid-list" do
    expect_raises(Scheme::SchemeIncompleteError) do
      Scheme::Reader.read_all("(1 2")
    end
  end

  it "raises SchemeIncompleteError on EOF right after a quote" do
    expect_raises(Scheme::SchemeIncompleteError) do
      Scheme::Reader.read_all("'")
    end
  end

  it "raises SchemeIncompleteError on EOF right after a dot" do
    expect_raises(Scheme::SchemeIncompleteError) do
      Scheme::Reader.read_all("(a .")
    end
  end

  it "raises SchemeIncompleteError on EOF right after the dotted tail (unbalanced paren)" do
    expect_raises(Scheme::SchemeIncompleteError) do
      Scheme::Reader.read_all("(a . b")
    end
  end

  it "raises SchemeParseError on an unexpected ')'" do
    expect_raises(Scheme::SchemeParseError, /unexpected '\)'/) do
      Scheme::Reader.read_all(")")
    end
  end

  it "raises SchemeParseError on a stray '.' at top level" do
    expect_raises(Scheme::SchemeParseError, /unexpected '\.'/) do
      Scheme::Reader.read_all(".")
    end
  end

  it "raises SchemeParseError when a dotted tail isn't followed by ')'" do
    expect_raises(Scheme::SchemeParseError, /expected '\)' after dotted tail/) do
      Scheme::Reader.read_all("(a . b c)")
    end
  end

  it "reads a vector literal" do
    forms = Scheme::Reader.read_all("#(1 2 3)")
    vec = forms[0].as(Scheme::SchemeVector)
    vec.value.map(&.as(Scheme::SchemeInt).value).should eq([1_i64, 2_i64, 3_i64])
  end

  it "reads an empty vector literal" do
    forms = Scheme::Reader.read_all("#()")
    forms[0].as(Scheme::SchemeVector).value.should be_empty
  end

  it "reads nested vector literals" do
    forms = Scheme::Reader.read_all("#(1 #(2 3))")
    outer = forms[0].as(Scheme::SchemeVector)
    outer.value[0].as(Scheme::SchemeInt).value.should eq(1_i64)
    inner = outer.value[1].as(Scheme::SchemeVector)
    inner.value.map(&.as(Scheme::SchemeInt).value).should eq([2_i64, 3_i64])
  end

  it "raises SchemeParseError on a stray '.' inside a vector literal" do
    expect_raises(Scheme::SchemeParseError, /unexpected '\.' inside vector literal/) do
      Scheme::Reader.read_all("#(1 . 2)")
    end
  end

  it "raises SchemeIncompleteError on an unbalanced vector literal" do
    expect_raises(Scheme::SchemeIncompleteError) do
      Scheme::Reader.read_all("#(1 2")
    end
  end

  it "reads a bytevector literal" do
    forms = Scheme::Reader.read_all("#u8(1 2 3)")
    forms[0].as(Scheme::SchemeBlob).value.should eq(Bytes[1, 2, 3])
  end

  it "reads an empty bytevector literal" do
    forms = Scheme::Reader.read_all("#u8()")
    forms[0].as(Scheme::SchemeBlob).value.should be_empty
  end

  it "reads a bytevector literal with byte values at the 0/255 boundary" do
    forms = Scheme::Reader.read_all("#u8(0 255)")
    forms[0].as(Scheme::SchemeBlob).value.should eq(Bytes[0, 255])
  end

  it "raises SchemeParseError for an out-of-range byte value in a bytevector literal" do
    expect_raises(Scheme::SchemeParseError, /out of range/) { Scheme::Reader.read_all("#u8(256)") }
    expect_raises(Scheme::SchemeParseError, /out of range/) { Scheme::Reader.read_all("#u8(-1)") }
  end

  it "raises SchemeParseError for a non-integer element in a bytevector literal" do
    expect_raises(Scheme::SchemeParseError, /must be integers/) { Scheme::Reader.read_all("#u8(1.5)") }
  end

  it "raises SchemeParseError on a stray '.' inside a bytevector literal" do
    expect_raises(Scheme::SchemeParseError, /unexpected '\.' inside bytevector literal/) do
      Scheme::Reader.read_all("#u8(1 . 2)")
    end
  end

  it "raises SchemeIncompleteError on an unbalanced bytevector literal" do
    expect_raises(Scheme::SchemeIncompleteError) do
      Scheme::Reader.read_all("#u8(1 2")
    end
  end

  it "reads a complex literal with both real and imaginary parts" do
    c = Scheme::Reader.read_all("3+4i")[0].as(Scheme::SchemeComplex)
    c.real.as(Scheme::SchemeInt).value.should eq(3_i64)
    c.imag.as(Scheme::SchemeInt).value.should eq(4_i64)
  end

  it "reads a complex literal with a negative imaginary part" do
    c = Scheme::Reader.read_all("3-4i")[0].as(Scheme::SchemeComplex)
    c.real.as(Scheme::SchemeInt).value.should eq(3_i64)
    c.imag.as(Scheme::SchemeInt).value.should eq(-4_i64)
  end

  it "reads a pure-imaginary literal with no real part" do
    c = Scheme::Reader.read_all("2i")[0].as(Scheme::SchemeComplex)
    c.real.as(Scheme::SchemeInt).value.should eq(0_i64)
    c.imag.as(Scheme::SchemeInt).value.should eq(2_i64)
  end

  it "reads a negative pure-imaginary literal" do
    c = Scheme::Reader.read_all("-2i")[0].as(Scheme::SchemeComplex)
    c.imag.as(Scheme::SchemeInt).value.should eq(-2_i64)
  end

  it "reads +i and -i as unit imaginary magnitude" do
    plus_i = Scheme::Reader.read_all("+i")[0].as(Scheme::SchemeComplex)
    plus_i.imag.as(Scheme::SchemeInt).value.should eq(1_i64)
    minus_i = Scheme::Reader.read_all("-i")[0].as(Scheme::SchemeComplex)
    minus_i.imag.as(Scheme::SchemeInt).value.should eq(-1_i64)
  end

  it "reads float real/imaginary components" do
    c = Scheme::Reader.read_all("1.5+0.5i")[0].as(Scheme::SchemeComplex)
    c.real.as(Scheme::SchemeFloat).value.should eq(1.5)
    c.imag.as(Scheme::SchemeFloat).value.should eq(0.5)
  end

  it "does not misinterpret a float exponent sign as the real/imag separator" do
    c = Scheme::Reader.read_all("1e10+2i")[0].as(Scheme::SchemeComplex)
    c.real.as(Scheme::SchemeFloat).value.should eq(1e10)
    c.imag.as(Scheme::SchemeInt).value.should eq(2_i64)
  end

  it "collapses a complex literal with an exact zero imaginary part to a plain real" do
    Scheme::Reader.read_all("3+0i")[0].should be_a(Scheme::SchemeInt)
  end

  describe "#; datum comments" do
    it "skips a leading datum" do
      forms = Scheme::Reader.read_all("#;1 2")
      forms.size.should eq(1)
      forms[0].as(Scheme::SchemeInt).value.should eq(2_i64)
    end

    it "skips a datum in the middle of a list" do
      forms = Scheme::Reader.read_all("(1 #;2 3)")
      forms[0].write_string.should eq("(1 3)")
    end

    it "skips a whole compound (nested) datum as one unit" do
      forms = Scheme::Reader.read_all("(1 #;(a (b c) d) 2)")
      forms[0].write_string.should eq("(1 2)")
    end

    it "handles consecutive datum comments" do
      forms = Scheme::Reader.read_all("#; #; a b c")
      forms.size.should eq(1)
      forms[0].as(Scheme::SchemeSym).name.should eq("c")
    end

    it "handles a datum comment as an entire top-level form" do
      forms = Scheme::Reader.read_all("#;(this is discarded) 5")
      forms.size.should eq(1)
      forms[0].as(Scheme::SchemeInt).value.should eq(5_i64)
    end
  end

  describe "#| ... |# block comments" do
    it "is invisible to the reader, same as whitespace" do
      forms = Scheme::Reader.read_all("#| comment |# (1 2 3)")
      forms.size.should eq(1)
      forms[0].write_string.should eq("(1 2 3)")
    end

    it "nests" do
      forms = Scheme::Reader.read_all("#| outer #| inner |# still outer |# 42")
      forms[0].as(Scheme::SchemeInt).value.should eq(42_i64)
    end

    it "interleaves correctly with real code and other comment kinds" do
      src = <<-SCM
        ; line comment
        #| block comment |#
        (display 1) ; trailing line comment
        #;(display 2)
        (display 3)
        SCM
      forms = Scheme::Reader.read_all(src)
      forms.size.should eq(2)
    end
  end
end
