require "../../spec_helper"

private def kinds(src : String) : Array(Scheme::TokKind)
  Scheme::Lexer.tokenize(src).map(&.kind)
end

private def texts(src : String) : Array(String)
  Scheme::Lexer.tokenize(src).map(&.text)
end

describe Scheme::Lexer do
  it "tokenizes parens (both styles)" do
    kinds("( ) [ ]").should eq([
      Scheme::TokKind::LParen, Scheme::TokKind::RParen,
      Scheme::TokKind::LParen, Scheme::TokKind::RParen,
      Scheme::TokKind::EOF,
    ])
  end

  it "tokenizes quote sugar" do
    kinds("' ` , ,@").should eq([
      Scheme::TokKind::Quote, Scheme::TokKind::Quasiquote,
      Scheme::TokKind::Unquote, Scheme::TokKind::UnquoteSplicing,
      Scheme::TokKind::EOF,
    ])
  end

  it "tokenizes a string literal" do
    toks = Scheme::Lexer.tokenize(%("hello"))
    toks[0].kind.should eq(Scheme::TokKind::StrLit)
    toks[0].text.should eq("hello")
  end

  it "processes string escapes" do
    toks = Scheme::Lexer.tokenize(%("a\\nb\\tc\\"d\\\\e\\r f\\0g"))
    toks[0].text.should eq("a\nb\tc\"d\\e\r f\0g")
  end

  it "raises on an unterminated string" do
    expect_raises(Scheme::SchemeParseError, /unterminated string/) do
      Scheme::Lexer.tokenize(%("abc))
    end
  end

  it "raises on an unterminated string escape" do
    expect_raises(Scheme::SchemeParseError, /unterminated string escape/) do
      Scheme::Lexer.tokenize(%("abc\\))
    end
  end

  it "tokenizes booleans: #t and #f" do
    toks = Scheme::Lexer.tokenize("#t #f")
    toks[0].kind.should eq(Scheme::TokKind::BoolLit)
    toks[0].text.should eq("#t")
    toks[1].kind.should eq(Scheme::TokKind::BoolLit)
    toks[1].text.should eq("#f")
  end

  it "tokenizes long-form booleans: #true and #false" do
    toks = Scheme::Lexer.tokenize("#true #false")
    toks[0].text.should eq("#t")
    toks[1].text.should eq("#f")
  end

  it "raises on unknown # syntax" do
    expect_raises(Scheme::SchemeParseError, /unknown # syntax/) do
      Scheme::Lexer.tokenize("#zzz")
    end
  end

  it "tokenizes a plain char literal" do
    toks = Scheme::Lexer.tokenize(%(#\\x))
    toks[0].kind.should eq(Scheme::TokKind::CharLit)
    toks[0].text.should eq("x")
  end

  it "tokenizes named char literals" do
    {"space" => " ", "newline" => "\n", "tab" => "\t", "return" => "\r", "nul" => "\0"}.each do |name, expected_char|
      toks = Scheme::Lexer.tokenize("#\\#{name}")
      toks[0].kind.should eq(Scheme::TokKind::CharLit)
      toks[0].text.should eq(expected_char)
    end
  end

  it "raises on an unknown named char" do
    expect_raises(Scheme::SchemeParseError, /unknown char name/) do
      Scheme::Lexer.tokenize(%(#\\bogus))
    end
  end

  it "raises on an unterminated char literal" do
    expect_raises(Scheme::SchemeParseError, /unterminated char literal/) do
      Scheme::Lexer.tokenize("#\\")
    end
  end

  it "skips comments to end of line" do
    toks = Scheme::Lexer.tokenize("1 ; a comment\n2")
    toks.map(&.kind).should eq([Scheme::TokKind::IntLit, Scheme::TokKind::IntLit, Scheme::TokKind::EOF])
  end

  it "tokenizes integers, including negatives" do
    kinds("42 -7 +3").should eq([Scheme::TokKind::IntLit, Scheme::TokKind::IntLit, Scheme::TokKind::IntLit, Scheme::TokKind::EOF])
  end

  it "raises on an out-of-range integer literal" do
    expect_raises(Scheme::SchemeParseError, /integer literal out of range/) do
      Scheme::Lexer.tokenize("999999999999999999999999999999")
    end
  end

  it "tokenizes floats" do
    kinds("3.14 -0.5 .5 2. 1e10 1.5e-3").should eq(Array.new(6) { Scheme::TokKind::FloatLit } + [Scheme::TokKind::EOF])
  end

  it "tokenizes complex literals" do
    kinds("3+4i 3-4i +4i -4i +i -i 1.5+0.5i 2i -1.5i").should eq(
      Array.new(9) { Scheme::TokKind::ComplexLit } + [Scheme::TokKind::EOF]
    )
  end

  it "does not confuse a float exponent's sign with the complex real/imag separator" do
    kinds("1e10+2i").should eq([Scheme::TokKind::ComplexLit, Scheme::TokKind::EOF])
  end

  it "tokenizes a dot token for dotted pairs" do
    toks = Scheme::Lexer.tokenize("(a . b)")
    toks.map(&.kind).should eq([
      Scheme::TokKind::LParen, Scheme::TokKind::Symbol, Scheme::TokKind::Dot,
      Scheme::TokKind::Symbol, Scheme::TokKind::RParen, Scheme::TokKind::EOF,
    ])
  end

  it "tokenizes plain symbols" do
    toks = Scheme::Lexer.tokenize("foo-bar? set!")
    toks[0].kind.should eq(Scheme::TokKind::Symbol)
    toks[0].text.should eq("foo-bar?")
    toks[1].text.should eq("set!")
  end

  it "tracks line and column numbers" do
    toks = Scheme::Lexer.tokenize("a\nb")
    toks[0].line.should eq(1)
    toks[1].line.should eq(2)
  end

  it "produces a single EOF token for empty input" do
    kinds("").should eq([Scheme::TokKind::EOF])
  end

  describe "#| ... |# block comments" do
    it "is skipped entirely, producing no token" do
      kinds("#| a comment |# 42").should eq([Scheme::TokKind::IntLit, Scheme::TokKind::EOF])
    end

    it "nests" do
      kinds("#| outer #| inner |# still outer |# 42").should eq([Scheme::TokKind::IntLit, Scheme::TokKind::EOF])
    end

    it "can contain a ';' or unbalanced parens without ending early or breaking" do
      kinds("#| ; not a line comment ( unbalanced |# 42").should eq([Scheme::TokKind::IntLit, Scheme::TokKind::EOF])
    end

    it "raises SchemeIncompleteError when unterminated" do
      expect_raises(Scheme::SchemeIncompleteError, /unterminated block comment/) do
        Scheme::Lexer.tokenize("#| never closed")
      end
    end

    it "raises SchemeIncompleteError when a nested comment is unterminated" do
      expect_raises(Scheme::SchemeIncompleteError, /unterminated block comment/) do
        Scheme::Lexer.tokenize("#| outer #| inner never closed")
      end
    end
  end

  describe "#; datum comments" do
    it "tokenizes as a distinct mark, not consumed at the lexer level" do
      kinds("#; 1 2").should eq([Scheme::TokKind::DatumCommentMark, Scheme::TokKind::IntLit, Scheme::TokKind::IntLit, Scheme::TokKind::EOF])
    end
  end
end
