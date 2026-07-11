# ===========================================================================
# Lexer
# ===========================================================================

module LISP
  enum TokKind
    LParen
    RParen
    Quote
    Quasiquote
    Unquote
    UnquoteSplicing
    IntLit
    FloatLit
    StrLit
    BoolLit
    CharLit
    Symbol
    Dot
    VectorOpen
    EOF
  end

  record Token, kind : TokKind, text : String, line : Int32, col : Int32, source : String

  class Lexer
    INT_RE   = /\A[+-]?\d+\z/
    FLOAT_RE = /\A[+-]?(\d+\.\d*|\.\d+|\d+)([eE][+-]?\d+)?\z/

    def initialize(@src : String, @source_name : String = "<unknown>")
      @chars = @src.chars
      @pos = 0
      @line = 1
      @col = 1
    end

    def self.tokenize(src : String, source_name : String = "<unknown>") : Array(Token)
      new(src, source_name).tokenize
    end

    private def tok(kind : TokKind, text : String, line : Int32, col : Int32) : Token
      Token.new(kind, text, line, col, @source_name)
    end

    def tokenize : Array(Token)
      tokens = [] of Token
      loop do
        t = next_token
        tokens << t
        break if t.kind == TokKind::EOF
      end
      tokens
    end

    private def eof? : Bool
      @pos >= @chars.size
    end

    private def peek : Char?
      return nil if eof?
      @chars[@pos]
    end

    private def peek2 : Char?
      return nil if @pos + 1 >= @chars.size
      @chars[@pos + 1]
    end

    private def advance : Char
      c = @chars[@pos]
      @pos += 1
      if c == '\n'
        @line += 1
        @col = 1
      else
        @col += 1
      end
      c
    end

    private def delimiter?(c : Char) : Bool
      case c
      when ' ', '\t', '\r', '\n', '(', ')', '[', ']', '"', ';', '\'', '`', ','
        true
      else
        false
      end
    end

    private def next_token : Token
      skip_whitespace_and_comments
      line = @line
      col = @col
      c = peek
      if c.nil?
        return tok(TokKind::EOF, "", line, col)
      end

      case c
      when '(', '['
        advance
        tok(TokKind::LParen, c.to_s, line, col)
      when ')', ']'
        advance
        tok(TokKind::RParen, c.to_s, line, col)
      when '\''
        advance
        tok(TokKind::Quote, "'", line, col)
      when '`'
        advance
        tok(TokKind::Quasiquote, "`", line, col)
      when ','
        advance
        if peek == '@'
          advance
          tok(TokKind::UnquoteSplicing, ",@", line, col)
        else
          tok(TokKind::Unquote, ",", line, col)
        end
      when '"'
        lex_string(line, col)
      when '#'
        lex_hash(line, col)
      else
        lex_atom(line, col)
      end
    end

    private def skip_whitespace_and_comments : Nil
      loop do
        c = peek
        break if c.nil?
        case c
        when ' ', '\t', '\r', '\n'
          advance
        when ';'
          while (ch = peek) && ch != '\n'
            advance
          end
        else
          break
        end
      end
    end

    private def lex_string(line : Int32, col : Int32) : Token
      advance # opening quote
      buf = String::Builder.new
      loop do
        if eof?
          raise LispParseError.new("unterminated string at #{line}:#{col}")
        end
        c = advance
        if c == '"'
          break
        elsif c == '\\'
          if eof?
            raise LispParseError.new("unterminated string escape at #{@line}:#{@col}")
          end
          e = advance
          case e
          when '"'  then buf << '"'
          when '\\' then buf << '\\'
          when 'n'  then buf << '\n'
          when 't'  then buf << '\t'
          when 'r'  then buf << '\r'
          when '0'  then buf << '\0'
          else           buf << e
          end
        else
          buf << c
        end
      end
      tok(TokKind::StrLit, buf.to_s, line, col)
    end

    private def lex_hash(line : Int32, col : Int32) : Token
      # peek is '#'
      nxt = peek2
      if nxt == '\\'
        advance # '#'
        advance # '\'
        lex_char(line, col)
      elsif nxt == '('
        advance # '#'
        advance # '('
        tok(TokKind::VectorOpen, "#(", line, col)
      else
        # boolean or a symbol beginning with '#'
        text = read_atom_text
        case text
        when "#t", "#true"  then tok(TokKind::BoolLit, "#t", line, col)
        when "#f", "#false" then tok(TokKind::BoolLit, "#f", line, col)
        else
          raise LispParseError.new("unknown # syntax '#{text}' at #{line}:#{col}")
        end
      end
    end

    private def lex_char(line : Int32, col : Int32) : Token
      # cursor is right after "#\"
      if eof?
        raise LispParseError.new("unterminated char literal at #{line}:#{col}")
      end
      # Read a run of alphabetic chars for named chars; otherwise one char.
      first = advance
      if first.ascii_letter?
        buf = String::Builder.new
        buf << first
        while (c = peek) && c.ascii_letter?
          buf << advance
        end
        name = buf.to_s
        if name.size == 1
          return tok(TokKind::CharLit, name, line, col)
        end
        ch = case name.downcase
             when "space"   then ' '
             when "newline" then '\n'
             when "tab"     then '\t'
             when "return"  then '\r'
             when "nul"     then '\0'
             else
               raise LispParseError.new("unknown char name '#{name}' at #{line}:#{col}")
             end
        tok(TokKind::CharLit, ch.to_s, line, col)
      else
        tok(TokKind::CharLit, first.to_s, line, col)
      end
    end

    private def read_atom_text : String
      buf = String::Builder.new
      while (c = peek) && !delimiter?(c)
        buf << advance
      end
      buf.to_s
    end

    private def lex_atom(line : Int32, col : Int32) : Token
      text = read_atom_text
      if text == "."
        return tok(TokKind::Dot, ".", line, col)
      end

      if INT_RE.matches?(text)
        begin
          text.to_i64
          return tok(TokKind::IntLit, text, line, col)
        rescue ArgumentError
          raise LispParseError.new("integer literal out of range '#{text}' at #{line}:#{col}")
        end
      end

      if FLOAT_RE.matches?(text) && (text.includes?('.') || text.includes?('e') || text.includes?('E'))
        begin
          text.to_f64
          return tok(TokKind::FloatLit, text, line, col)
        rescue ArgumentError
          raise LispParseError.new("float literal invalid '#{text}' at #{line}:#{col}")
        end
      end

      tok(TokKind::Symbol, text, line, col)
    end
  end
end
