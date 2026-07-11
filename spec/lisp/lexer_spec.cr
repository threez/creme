require "../spec_helper"

private def kinds(src : String) : Array(LISP::TokKind)
  LISP::Lexer.tokenize(src).map(&.kind)
end

private def texts(src : String) : Array(String)
  LISP::Lexer.tokenize(src).map(&.text)
end

describe LISP::Lexer do
  it "tokenizes parens (both styles)" do
    kinds("( ) [ ]").should eq([
      LISP::TokKind::LParen, LISP::TokKind::RParen,
      LISP::TokKind::LParen, LISP::TokKind::RParen,
      LISP::TokKind::EOF,
    ])
  end

  it "tokenizes quote sugar" do
    kinds("' ` , ,@").should eq([
      LISP::TokKind::Quote, LISP::TokKind::Quasiquote,
      LISP::TokKind::Unquote, LISP::TokKind::UnquoteSplicing,
      LISP::TokKind::EOF,
    ])
  end

  it "tokenizes a string literal" do
    toks = LISP::Lexer.tokenize(%("hello"))
    toks[0].kind.should eq(LISP::TokKind::StrLit)
    toks[0].text.should eq("hello")
  end

  it "processes string escapes" do
    toks = LISP::Lexer.tokenize(%("a\\nb\\tc\\"d\\\\e\\r f\\0g"))
    toks[0].text.should eq("a\nb\tc\"d\\e\r f\0g")
  end

  it "raises on an unterminated string" do
    expect_raises(LISP::LispParseError, /unterminated string/) do
      LISP::Lexer.tokenize(%("abc))
    end
  end

  it "raises on an unterminated string escape" do
    expect_raises(LISP::LispParseError, /unterminated string escape/) do
      LISP::Lexer.tokenize(%("abc\\))
    end
  end

  it "tokenizes booleans: #t and #f" do
    toks = LISP::Lexer.tokenize("#t #f")
    toks[0].kind.should eq(LISP::TokKind::BoolLit)
    toks[0].text.should eq("#t")
    toks[1].kind.should eq(LISP::TokKind::BoolLit)
    toks[1].text.should eq("#f")
  end

  it "tokenizes long-form booleans: #true and #false" do
    toks = LISP::Lexer.tokenize("#true #false")
    toks[0].text.should eq("#t")
    toks[1].text.should eq("#f")
  end

  it "raises on unknown # syntax" do
    expect_raises(LISP::LispParseError, /unknown # syntax/) do
      LISP::Lexer.tokenize("#zzz")
    end
  end

  it "tokenizes a plain char literal" do
    toks = LISP::Lexer.tokenize(%(#\\x))
    toks[0].kind.should eq(LISP::TokKind::CharLit)
    toks[0].text.should eq("x")
  end

  it "tokenizes named char literals" do
    {"space" => " ", "newline" => "\n", "tab" => "\t", "return" => "\r", "nul" => "\0"}.each do |name, expected_char|
      toks = LISP::Lexer.tokenize("#\\#{name}")
      toks[0].kind.should eq(LISP::TokKind::CharLit)
      toks[0].text.should eq(expected_char)
    end
  end

  it "raises on an unknown named char" do
    expect_raises(LISP::LispParseError, /unknown char name/) do
      LISP::Lexer.tokenize(%(#\\bogus))
    end
  end

  it "raises on an unterminated char literal" do
    expect_raises(LISP::LispParseError, /unterminated char literal/) do
      LISP::Lexer.tokenize("#\\")
    end
  end

  it "skips comments to end of line" do
    toks = LISP::Lexer.tokenize("1 ; a comment\n2")
    toks.map(&.kind).should eq([LISP::TokKind::IntLit, LISP::TokKind::IntLit, LISP::TokKind::EOF])
  end

  it "tokenizes integers, including negatives" do
    kinds("42 -7 +3").should eq([LISP::TokKind::IntLit, LISP::TokKind::IntLit, LISP::TokKind::IntLit, LISP::TokKind::EOF])
  end

  it "raises on an out-of-range integer literal" do
    expect_raises(LISP::LispParseError, /integer literal out of range/) do
      LISP::Lexer.tokenize("999999999999999999999999999999")
    end
  end

  it "tokenizes floats" do
    kinds("3.14 -0.5 .5 2. 1e10 1.5e-3").should eq(Array.new(6) { LISP::TokKind::FloatLit } + [LISP::TokKind::EOF])
  end

  it "tokenizes a dot token for dotted pairs" do
    toks = LISP::Lexer.tokenize("(a . b)")
    toks.map(&.kind).should eq([
      LISP::TokKind::LParen, LISP::TokKind::Symbol, LISP::TokKind::Dot,
      LISP::TokKind::Symbol, LISP::TokKind::RParen, LISP::TokKind::EOF,
    ])
  end

  it "tokenizes plain symbols" do
    toks = LISP::Lexer.tokenize("foo-bar? set!")
    toks[0].kind.should eq(LISP::TokKind::Symbol)
    toks[0].text.should eq("foo-bar?")
    toks[1].text.should eq("set!")
  end

  it "tracks line and column numbers" do
    toks = LISP::Lexer.tokenize("a\nb")
    toks[0].line.should eq(1)
    toks[1].line.should eq(2)
  end

  it "produces a single EOF token for empty input" do
    kinds("").should eq([LISP::TokKind::EOF])
  end
end
