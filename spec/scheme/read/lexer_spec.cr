require "../../spec_helper"

private def kinds(src : String) : Array(Creme::TokKind)
  Creme::Lexer.tokenize(src).map(&.kind)
end

private def texts(src : String) : Array(String)
  Creme::Lexer.tokenize(src).map(&.text)
end

describe Creme::Lexer do
  it "tokenizes parens (both styles)" do
    kinds("( ) [ ]").should eq([
      Creme::TokKind::LParen, Creme::TokKind::RParen,
      Creme::TokKind::LParen, Creme::TokKind::RParen,
      Creme::TokKind::EOF,
    ])
  end

  it "tokenizes quote sugar" do
    kinds("' ` , ,@").should eq([
      Creme::TokKind::Quote, Creme::TokKind::Quasiquote,
      Creme::TokKind::Unquote, Creme::TokKind::UnquoteSplicing,
      Creme::TokKind::EOF,
    ])
  end

  it "tokenizes a string literal" do
    toks = Creme::Lexer.tokenize(%("hello"))
    toks[0].kind.should eq(Creme::TokKind::StrLit)
    toks[0].text.should eq("hello")
  end

  it "processes string escapes" do
    toks = Creme::Lexer.tokenize(%("a\\nb\\tc\\"d\\\\e\\r f\\0g"))
    toks[0].text.should eq("a\nb\tc\"d\\e\r f\0g")
  end

  it "raises on an unterminated string" do
    expect_raises(Creme::SchemeParseError, /unterminated string/) do
      Creme::Lexer.tokenize(%("abc))
    end
  end

  it "raises on an unterminated string escape" do
    expect_raises(Creme::SchemeParseError, /unterminated string escape/) do
      Creme::Lexer.tokenize(%("abc\\))
    end
  end

  it "tokenizes booleans: #t and #f" do
    toks = Creme::Lexer.tokenize("#t #f")
    toks[0].kind.should eq(Creme::TokKind::BoolLit)
    toks[0].text.should eq("#t")
    toks[1].kind.should eq(Creme::TokKind::BoolLit)
    toks[1].text.should eq("#f")
  end

  it "tokenizes long-form booleans: #true and #false" do
    toks = Creme::Lexer.tokenize("#true #false")
    toks[0].text.should eq("#t")
    toks[1].text.should eq("#f")
  end

  it "raises on unknown # syntax" do
    expect_raises(Creme::SchemeParseError, /unknown # syntax/) do
      Creme::Lexer.tokenize("#zzz")
    end
  end

  it "tokenizes a plain char literal" do
    toks = Creme::Lexer.tokenize(%(#\\x))
    toks[0].kind.should eq(Creme::TokKind::CharLit)
    toks[0].text.should eq("x")
  end

  it "tokenizes named char literals" do
    {"space" => " ", "newline" => "\n", "tab" => "\t", "return" => "\r", "nul" => "\0"}.each do |name, expected_char|
      toks = Creme::Lexer.tokenize("#\\#{name}")
      toks[0].kind.should eq(Creme::TokKind::CharLit)
      toks[0].text.should eq(expected_char)
    end
  end

  it "raises on an unknown named char" do
    expect_raises(Creme::SchemeParseError, /unknown char name/) do
      Creme::Lexer.tokenize(%(#\\bogus))
    end
  end

  it "raises on an unterminated char literal" do
    expect_raises(Creme::SchemeParseError, /unterminated char literal/) do
      Creme::Lexer.tokenize("#\\")
    end
  end

  it "skips comments to end of line" do
    toks = Creme::Lexer.tokenize("1 ; a comment\n2")
    toks.map(&.kind).should eq([Creme::TokKind::IntLit, Creme::TokKind::IntLit, Creme::TokKind::EOF])
  end

  it "tokenizes integers, including negatives" do
    kinds("42 -7 +3").should eq([Creme::TokKind::IntLit, Creme::TokKind::IntLit, Creme::TokKind::IntLit, Creme::TokKind::EOF])
  end

  it "tokenizes an integer literal too large for Int64 as a plain IntLit (escapes to BigInt at the parse step)" do
    kinds("999999999999999999999999999999").should eq([Creme::TokKind::IntLit, Creme::TokKind::EOF])
  end

  it "tokenizes floats" do
    kinds("3.14 -0.5 .5 2. 1e10 1.5e-3").should eq(Array.new(6) { Creme::TokKind::FloatLit } + [Creme::TokKind::EOF])
  end

  it "tokenizes complex literals" do
    kinds("3+4i 3-4i +4i -4i +i -i 1.5+0.5i 2i -1.5i").should eq(
      Array.new(9) { Creme::TokKind::ComplexLit } + [Creme::TokKind::EOF]
    )
  end

  it "does not confuse a float exponent's sign with the complex real/imag separator" do
    kinds("1e10+2i").should eq([Creme::TokKind::ComplexLit, Creme::TokKind::EOF])
  end

  it "tokenizes a dot token for dotted pairs" do
    toks = Creme::Lexer.tokenize("(a . b)")
    toks.map(&.kind).should eq([
      Creme::TokKind::LParen, Creme::TokKind::Symbol, Creme::TokKind::Dot,
      Creme::TokKind::Symbol, Creme::TokKind::RParen, Creme::TokKind::EOF,
    ])
  end

  it "tokenizes plain symbols" do
    toks = Creme::Lexer.tokenize("foo-bar? set!")
    toks[0].kind.should eq(Creme::TokKind::Symbol)
    toks[0].text.should eq("foo-bar?")
    toks[1].text.should eq("set!")
  end

  it "tracks line and column numbers" do
    toks = Creme::Lexer.tokenize("a\nb")
    toks[0].line.should eq(1)
    toks[1].line.should eq(2)
  end

  it "produces a single EOF token for empty input" do
    kinds("").should eq([Creme::TokKind::EOF])
  end

  describe "#| ... |# block comments" do
    it "is skipped entirely, producing no token" do
      kinds("#| a comment |# 42").should eq([Creme::TokKind::IntLit, Creme::TokKind::EOF])
    end

    it "nests" do
      kinds("#| outer #| inner |# still outer |# 42").should eq([Creme::TokKind::IntLit, Creme::TokKind::EOF])
    end

    it "can contain a ';' or unbalanced parens without ending early or breaking" do
      kinds("#| ; not a line comment ( unbalanced |# 42").should eq([Creme::TokKind::IntLit, Creme::TokKind::EOF])
    end

    it "raises SchemeIncompleteError when unterminated" do
      expect_raises(Creme::SchemeIncompleteError, /unterminated block comment/) do
        Creme::Lexer.tokenize("#| never closed")
      end
    end

    it "raises SchemeIncompleteError when a nested comment is unterminated" do
      expect_raises(Creme::SchemeIncompleteError, /unterminated block comment/) do
        Creme::Lexer.tokenize("#| outer #| inner never closed")
      end
    end
  end

  describe "#; datum comments" do
    it "tokenizes as a distinct mark, not consumed at the lexer level" do
      kinds("#; 1 2").should eq([Creme::TokKind::DatumCommentMark, Creme::TokKind::IntLit, Creme::TokKind::IntLit, Creme::TokKind::EOF])
    end
  end
end
