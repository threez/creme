# ===========================================================================
# Reader (tokens -> AST)
# ===========================================================================

module Creme
  class Reader
    MAX_DEPTH = 2000

    # Index into @tokens of the next unconsumed token — exposed so callers
    # reading incrementally from a stream (e.g. the `read` builtin) can tell
    # how many tokens read_form just consumed, to know what's left over.
    getter pos : Int32

    def initialize(@tokens : Array(Token))
      @pos = 0
      @depth = 0
      @labels = {} of Int32 => SchemeValue
    end

    def self.read_all(src : String, source_name : String = "<unknown>") : Array(SchemeValue)
      tokens = Lexer.tokenize(src, source_name)
      reader = new(tokens)
      forms = [] of SchemeValue
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

    def read_form : SchemeValue
      @labels.clear if @depth == 0 # a datum label's scope is the outermost datum it appears in — see R7RS §2.4
      @depth += 1
      if @depth > MAX_DEPTH
        raise SchemeParseError.new("nesting too deep")
      end
      begin
        read_form_inner
      ensure
        @depth -= 1
      end
    end

    # ameba:disable Metrics/CyclomaticComplexity
    private def read_form_inner : SchemeValue
      t = current
      case t.kind
      when TokKind::EOF
        raise SchemeIncompleteError.new("unexpected end of input")
      when TokKind::IntLit
        advance
        Creme.int_value(t.text.to_i64? || BigInt.new(t.text))
      when TokKind::RationalLit
        advance
        parse_rational_literal(t)
      when TokKind::FloatLit
        advance
        SchemeFloat.new(Lexer::INF_NAN_LITERALS[t.text]? || t.text.to_f64)
      when TokKind::ComplexLit
        advance
        parse_complex_literal(t)
      when TokKind::DatumCommentMark
        advance
        read_form       # consume and discard exactly one following datum
        read_form_inner # then read the actual next datum — recursion
        # naturally handles nested/consecutive #; (e.g. "#; #; a b c" skips
        # a then b, reads c) and #; appearing anywhere a datum is expected
        # (leading, mid-list, inside a nested form), with no extra
        # bookkeeping beyond the existing recursive-descent structure.
      when TokKind::DatumLabelDef
        advance
        read_datum_label_def(t)
      when TokKind::DatumLabelRef
        advance
        @labels[t.text.to_i32]? || raise SchemeParseError.new("datum label: #{t.text}# references an unclosed or undefined label at #{t.line}:#{t.col}")
      when TokKind::StrLit
        advance
        SchemeStr.new(t.text)
      when TokKind::BoolLit
        advance
        SchemeBool.of(t.text == "#t")
      when TokKind::CharLit
        advance
        SchemeChar.new(t.text[0])
      when TokKind::Symbol
        advance
        SchemeSym.of(t.text)
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
      when TokKind::BytevectorOpen
        advance
        read_bytevector
      when TokKind::RParen
        raise SchemeParseError.new("unexpected ')' at #{t.line}:#{t.col}")
      when TokKind::Dot
        raise SchemeParseError.new("unexpected '.' at #{t.line}:#{t.col}")
      else
        raise SchemeParseError.new("unexpected token at #{t.line}:#{t.col}")
      end
    end

    # #n=datum labels the datum that follows with n, for later reference via
    # #n#. If datum is itself a list or vector, it can genuinely be
    # (or contain) a cycle back to this same label — e.g. #0=(1 . #0#) — so
    # a placeholder of the right shape is registered under the label BEFORE
    # reading datum's contents, and patched in place with the real
    # car/cdr/elements once they're known, preserving the placeholder's
    # identity (any #0# encountered while reading datum's own contents
    # already resolved to this same placeholder object). Atoms/strings
    # can't contain a reference to their own label (there's nowhere inside
    # them for #n# to appear), so they're simply read and registered
    # after the fact — no placeholder needed.
    private def read_datum_label_def(label_tok : Token) : SchemeValue
      label = label_tok.text.to_i32
      raise SchemeParseError.new("datum label: #{label} already defined at #{label_tok.line}:#{label_tok.col}") if @labels.has_key?(label)

      case current.kind
      when TokKind::LParen
        opener = advance
        placeholder = Cons.new(NIL, NIL)
        @labels[label] = placeholder
        real = read_list(opener)
        if real.is_a?(Cons)
          placeholder.car = real.car
          placeholder.cdr = real.cdr
          placeholder.pos = real.pos
          placeholder
        else
          # ()  — the empty list is a valid, non-Cons "list" result.
          @labels[label] = real
          real
        end
      when TokKind::VectorOpen
        advance
        placeholder = SchemeVector.new
        @labels[label] = placeholder
        real = read_vector
        placeholder.value.concat(real.value)
        placeholder
      else
        real = read_form
        @labels[label] = real
        real
      end
    end

    private def wrap(sym : String, opener : Token) : SchemeValue
      if current.kind == TokKind::EOF
        raise SchemeIncompleteError.new("unexpected end of input after #{sym}")
      end
      inner = read_form
      stamp(Creme.a_to_list([SchemeSym.of(sym), inner] of SchemeValue), opener)
    end

    private def read_list(opener : Token) : SchemeValue
      elements = [] of SchemeValue
      tail : SchemeValue = NIL
      loop do
        t = current
        case t.kind
        when TokKind::EOF
          raise SchemeIncompleteError.new("unexpected end of input: unbalanced '('")
        when TokKind::RParen
          advance
          break
        when TokKind::Dot
          advance
          if current.kind == TokKind::EOF
            raise SchemeIncompleteError.new("unexpected end of input after '.'")
          end
          tail = read_form
          # require closing paren
          if current.kind == TokKind::EOF
            raise SchemeIncompleteError.new("unexpected end of input: unbalanced '('")
          end
          unless current.kind == TokKind::RParen
            raise SchemeParseError.new("expected ')' after dotted tail at #{current.line}:#{current.col}")
          end
          advance
          break
        else
          elements << read_form
        end
      end
      stamp(Creme.a_to_list(elements, tail), opener)
    end

    # Stamps only the spine Cons cells belonging to this list (not the cars,
    # which — if themselves lists — were already stamped with their own
    # opener's position when they were read).
    private def stamp(list : SchemeValue, opener : Token) : SchemeValue
      pos = SourcePos.new(opener.source, opener.line, opener.col)
      cur = list
      while cur.is_a?(Cons)
        cur.pos = pos
        cur = cur.cdr
      end
      list
    end

    private def read_vector : SchemeValue
      elements = [] of SchemeValue
      loop do
        t = current
        case t.kind
        when TokKind::EOF
          raise SchemeIncompleteError.new("unexpected end of input: unbalanced '#('")
        when TokKind::RParen
          advance
          break
        when TokKind::Dot
          raise SchemeParseError.new("unexpected '.' inside vector literal at #{t.line}:#{t.col}")
        else
          elements << read_form
        end
      end
      SchemeVector.new(elements)
    end

    private def read_bytevector : SchemeValue
      bytes = [] of UInt8
      loop do
        t = current
        case t.kind
        when TokKind::EOF
          raise SchemeIncompleteError.new("unexpected end of input: unbalanced '#u8('")
        when TokKind::RParen
          advance
          break
        when TokKind::Dot
          raise SchemeParseError.new("unexpected '.' inside bytevector literal at #{t.line}:#{t.col}")
        when TokKind::IntLit
          n = t.text.to_i64
          raise SchemeParseError.new("bytevector element out of range 0..255 at #{t.line}:#{t.col}") unless n >= 0 && n <= 255
          advance
          bytes << n.to_u8
        else
          raise SchemeParseError.new("bytevector elements must be integers in 0..255 at #{t.line}:#{t.col}")
        end
      end
      SchemeBlob.new(Bytes.new(bytes.size) { |i| bytes[i] })
    end

    # Parses a token already matched against Lexer::COMPLEX_RE — one of
    # 3+4i, 3-4i, -4i, +4i, -i, +i, 1.5+0.5i, 2i, -1.5i, etc. Splits off the
    # trailing 'i', then finds the LAST top-level '+'/'-' that's a genuine
    # real/imaginary separator — walking from the end, skipping any +/-
    # that's immediately preceded by 'e'/'E' (part of a float exponent like
    # "1e-10") AND skipping position 0 (a leading sign is part of the
    # number itself, e.g. "-4i", not a separator with an implied empty real
    # part before it). No such separator found means the whole text (sign
    # included) is just the imaginary magnitude with no real part at all
    # (e.g. "2i", "-2i", "1.5i").
    private def parse_complex_literal(t : Token) : SchemeValue
      text = t.text[0...-1] # strip trailing 'i'
      split_at = nil
      (text.size - 1).downto(1) do |i|
        c = text[i]
        next unless c == '+' || c == '-'
        prev = text[i - 1]
        next if prev == 'e' || prev == 'E' # part of a float exponent, not the real/imag separator
        split_at = i
        break
      end

      if split_at
        real = parse_real_component(text[0...split_at], t)
        sign = text[split_at]
        imag_digits = text[(split_at + 1)..]
        imag_magnitude = imag_digits.empty? ? SchemeInt.new(1_i64).as(RealComponent) : parse_real_component(imag_digits, t)
        imag = sign == '-' ? negate_real_component(imag_magnitude) : imag_magnitude
      else
        real = SchemeInt.new(0_i64).as(RealComponent)
        imag = case text
               when "+" then SchemeInt.new(1_i64).as(RealComponent)
               when "-" then SchemeInt.new(-1_i64).as(RealComponent)
               else          parse_real_component(text, t)
               end
      end

      SchemeComplex.make(real, imag)
    end

    # Parses a token matched against Lexer::RATIONAL_RE — <sign>?<digits>/
    # <digits>. Any leading sign belongs to the numerator (denominators are
    # always unsigned in this syntax). Delegates to SchemeRational.make for
    # the actual reduction, so e.g. 4/6 reads as the already-reduced 2/3,
    # and n/1 collapses to a plain exact integer, exactly as if the same
    # ratio had been produced by (/ n d) at runtime.
    private def parse_rational_literal(t : Token) : SchemeValue
      num_text, den_text = t.text.split('/', 2)
      num = num_text.to_i64? || BigInt.new(num_text)
      den = den_text.to_i64? || BigInt.new(den_text)
      SchemeRational.make(num, den)
    end

    private def parse_real_component(text : String, t : Token) : RealComponent
      if text.includes?('.') || text.includes?('e') || text.includes?('E')
        SchemeFloat.new(text.to_f64)
      else
        Creme.int_value(text.to_i64? || BigInt.new(text))
      end
    end

    private def negate_real_component(v : RealComponent) : RealComponent
      case v
      when SchemeInt   then SchemeInt.new(-v.value)
      when SchemeFloat then SchemeFloat.new(-v.value)
      else                  raise SchemeParseError.new("unexpected rational in complex literal")
      end
    end
  end
end
