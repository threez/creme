# ===========================================================================
# Reader (tokens -> AST)
# ===========================================================================

module LISP
  class Reader
    MAX_DEPTH = 2000

    def initialize(@tokens : Array(Token))
      @pos = 0
      @depth = 0
    end

    def self.read_all(src : String, source_name : String = "<unknown>") : Array(LispValue)
      tokens = Lexer.tokenize(src, source_name)
      reader = new(tokens)
      forms = [] of LispValue
      until reader.at_eof?
        forms << reader.read_form
      end
      forms
    end

    def at_eof? : Bool
      @tokens[@pos].kind == TokKind::EOF
    end

    private def current : Token
      @tokens[@pos]
    end

    private def advance : Token
      t = @tokens[@pos]
      @pos += 1 unless t.kind == TokKind::EOF
      t
    end

    def read_form : LispValue
      @depth += 1
      if @depth > MAX_DEPTH
        raise LispParseError.new("nesting too deep")
      end
      begin
        read_form_inner
      ensure
        @depth -= 1
      end
    end

    private def read_form_inner : LispValue
      t = current
      case t.kind
      when TokKind::EOF
        raise LispIncompleteError.new("unexpected end of input")
      when TokKind::IntLit
        advance
        LispInt.new(t.text.to_i64)
      when TokKind::FloatLit
        advance
        LispFloat.new(t.text.to_f64)
      when TokKind::StrLit
        advance
        LispStr.new(t.text)
      when TokKind::BoolLit
        advance
        LispBool.of(t.text == "#t")
      when TokKind::CharLit
        advance
        LispChar.new(t.text[0])
      when TokKind::Symbol
        advance
        LispSym.of(t.text)
      when TokKind::Quote
        advance
        wrap("quote", t)
      when TokKind::Quasiquote
        advance
        wrap("quasiquote", t)
      when TokKind::Unquote
        advance
        wrap("unquote", t)
      when TokKind::UnquoteSplicing
        advance
        wrap("unquote-splicing", t)
      when TokKind::LParen
        advance
        read_list(t)
      when TokKind::VectorOpen
        advance
        read_vector
      when TokKind::RParen
        raise LispParseError.new("unexpected ')' at #{t.line}:#{t.col}")
      when TokKind::Dot
        raise LispParseError.new("unexpected '.' at #{t.line}:#{t.col}")
      else
        raise LispParseError.new("unexpected token at #{t.line}:#{t.col}")
      end
    end

    private def wrap(sym : String, opener : Token) : LispValue
      if current.kind == TokKind::EOF
        raise LispIncompleteError.new("unexpected end of input after #{sym}")
      end
      inner = read_form
      stamp(LISP.a_to_list([LispSym.of(sym), inner] of LispValue), opener)
    end

    private def read_list(opener : Token) : LispValue
      elements = [] of LispValue
      tail : LispValue = NIL
      loop do
        t = current
        case t.kind
        when TokKind::EOF
          raise LispIncompleteError.new("unexpected end of input: unbalanced '('")
        when TokKind::RParen
          advance
          break
        when TokKind::Dot
          advance
          if current.kind == TokKind::EOF
            raise LispIncompleteError.new("unexpected end of input after '.'")
          end
          tail = read_form
          # require closing paren
          if current.kind == TokKind::EOF
            raise LispIncompleteError.new("unexpected end of input: unbalanced '('")
          end
          unless current.kind == TokKind::RParen
            raise LispParseError.new("expected ')' after dotted tail at #{current.line}:#{current.col}")
          end
          advance
          break
        else
          elements << read_form
        end
      end
      stamp(LISP.a_to_list(elements, tail), opener)
    end

    # Stamps only the spine Cons cells belonging to this list (not the cars,
    # which — if themselves lists — were already stamped with their own
    # opener's position when they were read).
    private def stamp(list : LispValue, opener : Token) : LispValue
      pos = SourcePos.new(opener.source, opener.line, opener.col)
      cur = list
      while cur.is_a?(Cons)
        cur.pos = pos
        cur = cur.cdr
      end
      list
    end

    private def read_vector : LispValue
      elements = [] of LispValue
      loop do
        t = current
        case t.kind
        when TokKind::EOF
          raise LispIncompleteError.new("unexpected end of input: unbalanced '#('")
        when TokKind::RParen
          advance
          break
        when TokKind::Dot
          raise LispParseError.new("unexpected '.' inside vector literal at #{t.line}:#{t.col}")
        else
          elements << read_form
        end
      end
      LispVector.new(elements)
    end
  end
end
