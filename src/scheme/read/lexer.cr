# ===========================================================================
# Lexer
# ===========================================================================

module Scheme
  enum TokKind
    LParen
    RParen
    Quote
    Quasiquote
    Unquote
    UnquoteSplicing
    IntLit
    RationalLit
    FloatLit
    ComplexLit
    StrLit
    BoolLit
    CharLit
    Symbol
    Dot
    VectorOpen
    BytevectorOpen
    DatumCommentMark
    DatumLabelDef
    DatumLabelRef
    EOF
  end

  record Token, kind : TokKind, text : String, line : Int32, col : Int32, source : String

  class Lexer
    INT_RE      = /\A[+-]?\d+\z/
    FLOAT_RE    = /\A[+-]?(\d+\.\d*|\.\d+|\d+)([eE][+-]?\d+)?\z/
    RATIONAL_RE = /\A[+-]?\d+\/\d+\z/

    # A real-number component, reused for both the real and imaginary parts
    # of a complex literal below.
    REAL_PART = /[+-]?(\d+\.\d*|\.\d+|\d+)([eE][+-]?\d+)?/
    UREAL     = /(\d+\.\d*|\.\d+|\d+)([eE][+-]?\d+)?/ # unsigned — the sign lives in the separating [+-] instead

    # Two shapes: a signed real directly followed by 'i' (2i, -2i, 1.5i —
    # the sign, if any, is already part of REAL_PART here, so there's no
    # separate real-part prefix), or a real-part followed by a MANDATORY
    # separating sign and an optional unsigned magnitude before 'i' (3+4i,
    # 3-4i, -4i, +4i, -i, +i). Matched whole so the trailing 'i' can't be
    # confused with a symbol starting with a digit (already invalid Scheme
    # syntax) or a plain real-number token.
    COMPLEX_RE = /\A(#{REAL_PART}i|(#{REAL_PART})?[+-](#{UREAL})?i)\z/

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

    private def peek_at(offset : Int32) : Char?
      idx = @pos + offset
      return nil if idx < 0 || idx >= @chars.size
      @chars[idx]
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
      when ' ', '\t', '\r', '\n', '(', ')', '[', ']', '"', ';', '\'', '`', ',', '|'
        true
      else
        false
      end
    end

    # ameba:disable Metrics/CyclomaticComplexity
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
      when '|'
        lex_piped_identifier(line, col)
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
        when '#'
          break unless peek2 == '|'
          skip_block_comment
        else
          break
        end
      end
    end

    # Consumes a #| ... |# block comment, nestable (an inner #| bumps depth,
    # a matching |# drops it — the whole thing is only fully consumed once
    # depth returns to 0). Pure lexer-level skip producing no token, same
    # as ; line comments above — datum comments (#;) are a different beast
    # (they skip exactly one following DATUM, which needs the reader's
    # recursive parsing, not a lexer-level character skip) and are handled
    # separately via TokKind::DatumCommentMark, dispatched in lex_hash.
    private def skip_block_comment : Nil
      start_line, start_col = @line, @col
      advance # '#'
      advance # '|'
      depth = 1
      while depth > 0
        if eof?
          raise SchemeIncompleteError.new("unterminated block comment starting at #{start_line}:#{start_col}")
        end
        if peek == '#' && peek2 == '|'
          advance
          advance
          depth += 1
        elsif peek == '|' && peek2 == '#'
          advance
          advance
          depth -= 1
        else
          advance
        end
      end
    end

    # ameba:disable Metrics/CyclomaticComplexity
    private def lex_string(line : Int32, col : Int32) : Token
      advance # opening quote
      buf = String::Builder.new
      loop do
        if eof?
          raise SchemeParseError.new("unterminated string at #{line}:#{col}")
        end
        c = advance
        if c == '"'
          break
        elsif c == '\\'
          if eof?
            raise SchemeParseError.new("unterminated string escape at #{@line}:#{@col}")
          end
          e = advance
          case e
          when '"'  then buf << '"'
          when '\\' then buf << '\\'
          when 'n'  then buf << '\n'
          when 't'  then buf << '\t'
          when 'r'  then buf << '\r'
          when '0'  then buf << '\0'
          when 'x'  then buf << lex_hex_escape(line, col)
          else           buf << e
          end
        else
          buf << c
        end
      end
      tok(TokKind::StrLit, buf.to_s, line, col)
    end

    # Consumes a \x<hex digits>; mnemonic escape's hex digits and terminating
    # semicolon (cursor is already past the "\x"), returning the decoded
    # character. Shared by string literals and |...| piped identifiers.
    private def lex_hex_escape(line : Int32, col : Int32) : Char
      buf = String::Builder.new
      while (c = peek) && c.to_i?(16)
        buf << advance
      end
      raise SchemeParseError.new("invalid \\x escape at #{line}:#{col}") if buf.bytesize == 0
      raise SchemeParseError.new("unterminated \\x escape (expected ';') at #{line}:#{col}") unless peek == ';'
      advance # ';'
      buf.to_s.to_i32(16).unsafe_chr
    end

    # |...| vertical-line identifiers (R7RS §2.1): any character verbatim
    # except backslash and the closing |, plus the same mnemonic/hex
    # escapes as string literals. Always emitted as a Symbol token — the
    # reader treats it exactly like an ordinary identifier, just with a
    # richer character set and no case-folding/leading-digit restriction.
    # ameba:disable Metrics/CyclomaticComplexity
    private def lex_piped_identifier(line : Int32, col : Int32) : Token
      advance # opening '|'
      buf = String::Builder.new
      loop do
        if eof?
          raise SchemeParseError.new("unterminated |...| identifier at #{line}:#{col}")
        end
        c = advance
        if c == '|'
          break
        elsif c == '\\'
          if eof?
            raise SchemeParseError.new("unterminated |...| identifier escape at #{@line}:#{@col}")
          end
          e = advance
          case e
          when '|'  then buf << '|'
          when '\\' then buf << '\\'
          when 'n'  then buf << '\n'
          when 't'  then buf << '\t'
          when 'r'  then buf << '\r'
          when 'a'  then buf << '\a'
          when 'b'  then buf << '\b'
          when '0'  then buf << '\0'
          when 'x'  then buf << lex_hex_escape(line, col)
          else           buf << e
          end
        else
          buf << c
        end
      end
      tok(TokKind::Symbol, buf.to_s, line, col)
    end

    # ameba:disable Metrics/CyclomaticComplexity
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
      elsif nxt == 'u' && peek_at(2) == '8' && peek_at(3) == '('
        advance # '#'
        advance # 'u'
        advance # '8'
        advance # '('
        tok(TokKind::BytevectorOpen, "#u8(", line, col)
      elsif nxt == ';'
        advance # '#'
        advance # ';'
        tok(TokKind::DatumCommentMark, "#;", line, col)
      elsif nxt && "bodxeiBODXEI".includes?(nxt)
        lex_prefixed_number(line, col)
      elsif nxt && nxt.ascii_number?
        lex_datum_label(line, col)
      else
        # boolean or a symbol beginning with '#'
        text = read_atom_text
        case text
        when "#t", "#true"  then tok(TokKind::BoolLit, "#t", line, col)
        when "#f", "#false" then tok(TokKind::BoolLit, "#f", line, col)
        else
          raise SchemeParseError.new("unknown # syntax '#{text}' at #{line}:#{col}")
        end
      end
    end

    # #<digits>=<datum> labels a datum for later reference; #<digits># is a
    # reference to a previously-labelled datum (R7RS §2.4). Both share a
    # digit run after the '#'; which one it is is only known once the
    # character immediately after the digits ('=' or '#') is seen. Reader
    # (not Lexer) maintains the label table, since resolving a reference —
    # and patching a genuine cycle in place — needs the parsed datum tree,
    # not just token text.
    private def lex_datum_label(line : Int32, col : Int32) : Token
      advance # '#'
      buf = String::Builder.new
      while (c = peek) && c.ascii_number?
        buf << advance
      end
      digits = buf.to_s
      case peek
      when '='
        advance
        tok(TokKind::DatumLabelDef, digits, line, col)
      when '#'
        advance
        tok(TokKind::DatumLabelRef, digits, line, col)
      else
        raise SchemeParseError.new("datum label: expected '=' or '#' after #{digits} at #{line}:#{col}")
      end
    end

    # A number can carry a radix prefix (#b/#o/#d/#x — binary/octal/decimal/
    # hexadecimal) and/or an exactness prefix (#e/#i — exact/inexact), in
    # either order, each appearing at most once (R7RS §7.1.1's <prefix>
    # production). Consumes zero or more #<letter> pairs, then the
    # remaining numeral text, and converts it — entirely lexer-side, so the
    # emitted token is always a plain base-10 IntLit/FloatLit and neither
    # Reader nor the rest of the pipeline needs to know prefixes existed.
    # ameba:disable Metrics/CyclomaticComplexity
    private def lex_prefixed_number(line : Int32, col : Int32) : Token
      radix = 10
      exactness : Char? = nil
      loop do
        break unless peek == '#'
        letter = peek2
        break unless letter
        case letter.downcase
        when 'b' then radix = 2
        when 'o' then radix = 8
        when 'd' then radix = 10
        when 'x' then radix = 16
        when 'e', 'i'
          raise SchemeParseError.new("numeric literal: duplicate exactness prefix at #{line}:#{col}") if exactness
          exactness = letter.downcase
        else
          break
        end
        advance # '#'
        advance # the prefix letter
      end

      text = read_atom_text
      raise SchemeParseError.new("numeric literal: expected digits after prefix at #{line}:#{col}") if text.empty?

      value = if radix == 10
                (text.to_i64? || text.to_f64?).as(Int64 | Float64 | Nil)
              else
                text.to_i64?(radix).as(Int64 | Float64 | Nil)
              end
      raise SchemeParseError.new("invalid numeric literal '#{text}' at #{line}:#{col}") unless value

      case exactness
      when 'i'
        tok(TokKind::FloatLit, value.to_f64.to_s, line, col)
      when 'e'
        tok(TokKind::IntLit, value.to_i64.to_s, line, col)
      else
        value.is_a?(Float64) ? tok(TokKind::FloatLit, value.to_s, line, col) : tok(TokKind::IntLit, value.to_s, line, col)
      end
    end

    # ameba:disable Metrics/CyclomaticComplexity
    private def lex_char(line : Int32, col : Int32) : Token
      # cursor is right after "#\"
      if eof?
        raise SchemeParseError.new("unterminated char literal at #{line}:#{col}")
      end
      # #\x<hex-scalar-value> — but only when a hex digit actually follows;
      # bare #\x (x immediately followed by a delimiter) is the ordinary
      # letter x, same as any other one-character literal.
      if peek == 'x' && (h = peek2) && h.to_i?(16)
        advance # 'x'
        buf = String::Builder.new
        while (c = peek) && c.to_i?(16)
          buf << advance
        end
        return tok(TokKind::CharLit, buf.to_s.to_i32(16).unsafe_chr.to_s, line, col)
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
             when "space"     then ' '
             when "newline"   then '\n'
             when "tab"       then '\t'
             when "return"    then '\r'
             when "nul"       then '\0'
             when "null"      then '\0'
             when "alarm"     then ''
             when "backspace" then ''
             when "delete"    then ''
             when "escape"    then ''
             else
               raise SchemeParseError.new("unknown char name '#{name}' at #{line}:#{col}")
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

    # The four special inexact-real spellings R7RS reserves regardless of
    # radix — infinities and NaN. -nan.0 is a synonym for +nan.0 (NaN has no
    # sign). Checked before the ordinary numeral regexes since none of them
    # match these (there are no digits to match).
    INF_NAN_LITERALS = {
      "+inf.0" => Float64::INFINITY,
      "-inf.0" => -Float64::INFINITY,
      "+nan.0" => Float64::NAN,
      "-nan.0" => Float64::NAN,
    }

    # ameba:disable Metrics/CyclomaticComplexity
    private def lex_atom(line : Int32, col : Int32) : Token
      text = read_atom_text
      if text == "."
        return tok(TokKind::Dot, ".", line, col)
      end

      if INF_NAN_LITERALS.has_key?(text)
        return tok(TokKind::FloatLit, text, line, col)
      end

      if INT_RE.matches?(text)
        begin
          text.to_i64
          return tok(TokKind::IntLit, text, line, col)
        rescue ArgumentError
          raise SchemeParseError.new("integer literal out of range '#{text}' at #{line}:#{col}")
        end
      end

      if RATIONAL_RE.matches?(text)
        return tok(TokKind::RationalLit, text, line, col)
      end

      if FLOAT_RE.matches?(text) && (text.includes?('.') || text.includes?('e') || text.includes?('E'))
        begin
          text.to_f64
          return tok(TokKind::FloatLit, text, line, col)
        rescue ArgumentError
          raise SchemeParseError.new("float literal invalid '#{text}' at #{line}:#{col}")
        end
      end

      if COMPLEX_RE.matches?(text)
        return tok(TokKind::ComplexLit, text, line, col)
      end

      tok(TokKind::Symbol, text, line, col)
    end
  end
end
