# ===========================================================================
# (creme reader): exposes the real Lexer/Reader to Scheme code as a
# token-stream hook, so a `#lang <library>` dialect's parser can be written
# in Scheme -- see src/creme/runner.cr's `#lang` handling and
# modules/creme/syntax/mex.sld for the first library built on top of this.
# ===========================================================================
#
# The split is deliberate: `lex-tokens` does all of the fiddly, already-
# correct lexical grammar (numbers, string escapes, block comments, char
# names, radix/exactness prefixes, ...) and hands back plain Scheme data;
# a dialect library reorders/filters/inserts elements of that list in pure
# Scheme (its own real syntactic transform); `tokens->forms` hands the
# (possibly rewritten) list back to the ordinary, unmodified Reader to
# produce real parsed forms. Neither builtin knows anything about any
# particular dialect.
module Creme::Builtins::ReaderLibrary
  extend self
  include Creme::BuiltinHelpers

  # Every TokKind, both directions -- an explicit table rather than a
  # derived-from-the-enum-name transform, since a few members (LParen,
  # RParen, EOF, ...) have no lowercase-before-uppercase letter boundary to
  # hyphenate on, which would make the two directions not invert cleanly.
  TOKKIND_TO_SYM = {
    TokKind::LParen           => "lparen",
    TokKind::RParen           => "rparen",
    TokKind::Quote            => "quote",
    TokKind::Quasiquote       => "quasiquote",
    TokKind::Unquote          => "unquote",
    TokKind::UnquoteSplicing  => "unquote-splicing",
    TokKind::IntLit           => "intlit",
    TokKind::RationalLit      => "rationallit",
    TokKind::FloatLit         => "floatlit",
    TokKind::ComplexLit       => "complexlit",
    TokKind::StrLit           => "strlit",
    TokKind::BoolLit          => "boollit",
    TokKind::CharLit          => "charlit",
    TokKind::Symbol           => "symbol",
    TokKind::Dot              => "dot",
    TokKind::VectorOpen       => "vectoropen",
    TokKind::BytevectorOpen   => "bytevectoropen",
    TokKind::DatumCommentMark => "datumcommentmark",
    TokKind::DatumLabelDef    => "datumlabeldef",
    TokKind::DatumLabelRef    => "datumlabelref",
    TokKind::EOF              => "eof",
  }
  SYM_TO_TOKKIND = TOKKIND_TO_SYM.to_a.to_h { |kind, sym| {sym, kind} }

  # (lex-tokens str source-name) -> a Scheme list of tokens, each token
  # itself a 4-element list (kind text line col) -- kind a symbol (see
  # TOKKIND_TO_SYM), text a string, line/col exact integers. Includes the
  # trailing EOF token, same as the real tokenizer's own output.
  @[Creme::SchemeFn("lex-tokens", min: 2, max: 2)]
  def lex_tokens(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    str = string_arg(args[0], "lex-tokens")
    source_name = string_arg(args[1], "lex-tokens")
    tokens = Lexer.tokenize(str, source_name)
    Creme.a_to_list(tokens.map { |tok| token_to_list(tok).as(SchemeValue) })
  end

  # (tokens->forms tokens source-name) -> a Scheme list of the forms
  # obtained by feeding `tokens` (in the shape lex-tokens produces, after
  # whatever a dialect's own Scheme code did to it) through the ordinary,
  # unmodified Reader.
  @[Creme::SchemeFn("tokens->forms", min: 2, max: 2)]
  def tokens_to_forms(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    source_name = string_arg(args[1], "tokens->forms")
    tokens = Creme.list_to_a(args[0]).map { |v| list_to_token(v, source_name) }
    reader = Reader.new(tokens)
    forms = [] of SchemeValue
    until reader.at_eof?
      forms << reader.read_form
    end
    Creme.a_to_list(forms)
  end

  private def token_to_list(t : Token) : SchemeValue
    kind_sym = TOKKIND_TO_SYM[t.kind]
    Creme.a_to_list([
      SchemeSym.of(kind_sym).as(SchemeValue),
      SchemeStr.new(t.text).as(SchemeValue),
      SchemeInt.new(t.line.to_i64).as(SchemeValue),
      SchemeInt.new(t.col.to_i64).as(SchemeValue),
    ])
  end

  private def list_to_token(v : SchemeValue, source_name : String) : Token
    parts = Creme.list_to_a(v)
    raise SchemeRuntimeError.new("tokens->forms: malformed token #{v.write_string}") unless parts.size == 4
    kind_sym = parts[0]
    raise SchemeRuntimeError.new("tokens->forms: token kind must be a symbol, got #{parts[0].write_string}") unless kind_sym.is_a?(SchemeSym)
    kind = SYM_TO_TOKKIND[kind_sym.name]? || raise SchemeRuntimeError.new("tokens->forms: unknown token kind '#{kind_sym.name}'")
    Token.new(kind, string_arg(parts[1], "tokens->forms"), int_arg(parts[2], "tokens->forms").to_i32, int_arg(parts[3], "tokens->forms").to_i32, source_name)
  end
end

module Creme
  class Interpreter
    register_library ["creme", "builtin", "reader"], Creme::Builtins::ReaderLibrary
  end
end
