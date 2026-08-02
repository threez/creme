# ===========================================================================
# define-syntax / syntax-rules
#
# A non-hygienic pattern-matching macro system: literals and `...` ellipsis
# are supported, but there is no alpha-renaming, so a template-introduced
# identifier CAN capture (or be captured by) a use-site identifier of the
# same name. This is a deliberate scope decision, not an oversight — it
# matches this project's existing `defmacro` precedent (also unhygienic,
# with manual `gensym` as the documented workaround) rather than attempting
# full hygiene, which is a substantial undertaking on its own. Authors who
# need capture-avoidance should gensym their template identifiers the same
# way defmacro authors already do.
# ===========================================================================

module Creme
  ELLIPSIS = "..."

  # One (define-syntax name (syntax-rules (literal...) (pattern template)...))
  # binding. `rules` pairs each pattern with its template; patterns include
  # the macro-name/keyword position (conventionally `_` or the macro name
  # itself), which match_pattern always treats as a wildcard.
  class SchemeSyntaxRules
    include SchemeBaseValue
    getter name : String
    getter literals : Array(String)
    getter rules : Array({SchemeValue, SchemeValue})

    def initialize(@name : String, @literals : Array(String), @rules : Array({SchemeValue, SchemeValue}))
    end

    def to_display(io : IO) : Nil
      io << "#<syntax-rules:" << @name << '>'
    end
  end

  # A pattern variable's binding: either a single matched form, or (when
  # matched under a `...`) an array of matches — one per repetition.
  alias SyntaxBinding = SchemeValue | Array(SyntaxBinding)

  # Structurally matches `form` against `pattern`. Returns the pattern
  # variable bindings on success, nil on failure. `_` matches anything
  # without binding; a symbol listed in `literals` must match itself
  # (by name) and does not bind; any other symbol binds to the
  # corresponding form. `(p ... . rest)` matches zero-or-more repetitions
  # of `p` against a prefix of the list, then matches `rest` against
  # whatever's left.
  def self.match_pattern(pattern : SchemeValue, form : SchemeValue, literals : Array(String)) : Hash(String, SyntaxBinding)?
    bindings = {} of String => SyntaxBinding
    match_into(pattern, form, literals, bindings) ? bindings : nil
  end

  private def self.match_into(pattern : SchemeValue, form : SchemeValue, literals : Array(String), bindings : Hash(String, SyntaxBinding)) : Bool
    case pattern
    when SchemeSym
      return true if pattern.name == "_"
      if literals.includes?(pattern.name)
        return form.is_a?(SchemeSym) && form.name == pattern.name
      end
      bindings[pattern.name] = form
      true
    when Cons
      match_list(pattern, form, literals, bindings)
    when SchemeNil
      form.is_a?(SchemeNil)
    else
      Creme.scheme_equal?(pattern, form)
    end
  end

  private def self.match_list(pattern : Cons, form : SchemeValue, literals : Array(String), bindings : Hash(String, SyntaxBinding)) : Bool
    if (cdr = pattern.cdr).is_a?(Cons) && (second = cdr.car).is_a?(SchemeSym) && second.name == ELLIPSIS
      return match_ellipsis(pattern.car, cdr.cdr, form, literals, bindings)
    end
    return false unless form.is_a?(Cons)
    match_into(pattern.car, form.car, literals, bindings) && match_into(pattern.cdr, form.cdr, literals, bindings)
  end

  # Matches `sub_pattern ... rest_pattern` against `form`: greedily collects
  # repetitions of sub_pattern from the front, leaving exactly enough for
  # rest_pattern to match the tail.
  private def self.match_ellipsis(sub_pattern : SchemeValue, rest_pattern : SchemeValue, form : SchemeValue, literals : Array(String), bindings : Hash(String, SyntaxBinding)) : Bool
    items = [] of SchemeValue
    cur = form
    while cur.is_a?(Cons)
      items << cur.car
      cur = cur.cdr
    end
    tail = cur
    min_rest = Creme.proper_list?(rest_pattern) ? Creme.list_to_a(rest_pattern).size : 0
    return false if items.size < min_rest
    repeat_count = items.size - min_rest

    vars = pattern_vars(sub_pattern, literals)
    per_var = Hash(String, Array(SyntaxBinding)).new { |hash, key| hash[key] = [] of SyntaxBinding }
    repeat_count.times do |i|
      sub_bindings = {} of String => SyntaxBinding
      return false unless match_into(sub_pattern, items[i], literals, sub_bindings)
      vars.each { |v| per_var[v] << sub_bindings[v] }
    end
    vars.each { |v| bindings[v] = per_var[v] }

    rest_form = Creme.a_to_list(items[repeat_count..], tail)
    match_into(rest_pattern, rest_form, literals, bindings)
  end

  # Pattern variable names bound anywhere inside `pattern` (excluding `_`
  # and listed literals) — used to know which bindings an ellipsis
  # repetition produces, even for repetitions that bind nothing directly
  # (an empty repeat still needs each var initialized to an empty array).
  private def self.pattern_vars(pattern : SchemeValue, literals : Array(String)) : Array(String)
    case pattern
    when SchemeSym
      pattern.name == "_" || pattern.name == ELLIPSIS || literals.includes?(pattern.name) ? [] of String : [pattern.name]
    when Cons
      pattern_vars(pattern.car, literals) + pattern_vars(pattern.cdr, literals)
    else
      [] of String
    end
  end

  # Instantiates `template` by substituting pattern variable bindings.
  # `(t ... . rest)` where `t` contains an ellipsis-bound (array) variable
  # expands to one copy of `t` per element, zipping ellipsis-bound
  # variables together positionally; non-ellipsis variables referenced
  # inside `t` are held constant across every copy. Symbols not present in
  # `bindings` pass through unchanged — this (lack of renaming) is the
  # unhygienic part.
  def self.instantiate_template(template : SchemeValue, bindings : Hash(String, SyntaxBinding)) : SchemeValue
    case template
    when SchemeSym
      bindings.has_key?(template.name) ? single_binding(bindings[template.name], template.name) : template
    when Cons
      if escaped = ellipsis_escape?(template)
        instantiate_verbatim(escaped, bindings)
      else
        instantiate_list(template, bindings)
      end
    else
      template
    end
  end

  # Recognizes a template of the form (... escaped) — the R7RS
  # literal-ellipsis-escape idiom, used so a macro's own generated template
  # can itself contain a literal `...` (e.g. a macro that expands into
  # another define-syntax/syntax-rules form). Returns the escaped
  # sub-template, or nil if `template` isn't in that shape.
  private def self.ellipsis_escape?(template : Cons) : SchemeValue?
    return nil unless (head = template.car).is_a?(SchemeSym) && head.name == ELLIPSIS
    rest = template.cdr
    return nil unless rest.is_a?(Cons) && rest.cdr.is_a?(SchemeNil)
    rest.car
  end

  # Instantiates an ellipsis-escaped sub-template: pattern variables still
  # substitute normally, but any `...` inside `template` is now an ordinary
  # symbol, never treated as the ellipsis marker.
  private def self.instantiate_verbatim(template : SchemeValue, bindings : Hash(String, SyntaxBinding)) : SchemeValue
    case template
    when SchemeSym
      bindings.has_key?(template.name) ? single_binding(bindings[template.name], template.name) : template
    when Cons
      Cons.new(instantiate_verbatim(template.car, bindings), instantiate_verbatim(template.cdr, bindings))
    else
      template
    end
  end

  private def self.single_binding(b : SyntaxBinding, name : String) : SchemeValue
    raise SchemeRuntimeError.new("syntax-rules: '#{name}' used without '...' but was matched under one") if b.is_a?(Array)
    b
  end

  private def self.instantiate_list(template : Cons, bindings : Hash(String, SyntaxBinding)) : SchemeValue
    if (cdr = template.cdr).is_a?(Cons) && (second = cdr.car).is_a?(SchemeSym) && second.name == ELLIPSIS
      expanded = instantiate_ellipsis(template.car, bindings)
      rest = instantiate_template(cdr.cdr, bindings)
      return Creme.a_to_list(expanded, rest)
    end
    Cons.new(instantiate_template(template.car, bindings), instantiate_template(template.cdr, bindings))
  end

  private def self.instantiate_ellipsis(sub_template : SchemeValue, bindings : Hash(String, SyntaxBinding)) : Array(SchemeValue)
    vars = template_ellipsis_vars(sub_template, bindings)
    return [] of SchemeValue if vars.empty?
    count = bindings[vars.first].as(Array(SyntaxBinding)).size
    Array(SchemeValue).new(count) do |i|
      sub_bindings = bindings.dup
      vars.each { |v| sub_bindings[v] = bindings[v].as(Array(SyntaxBinding))[i] }
      instantiate_template(sub_template, sub_bindings)
    end
  end

  # Names inside sub_template that are bound to an ellipsis repetition
  # (an Array) in `bindings` — these drive how many copies to produce.
  private def self.template_ellipsis_vars(sub_template : SchemeValue, bindings : Hash(String, SyntaxBinding)) : Array(String)
    case sub_template
    when SchemeSym
      (b = bindings[sub_template.name]?) && b.is_a?(Array) ? [sub_template.name] : [] of String
    when Cons
      template_ellipsis_vars(sub_template.car, bindings) + template_ellipsis_vars(sub_template.cdr, bindings)
    else
      [] of String
    end
  end

  class Interpreter
    # (define-syntax name (syntax-rules (literal...) (pattern template)...))
    def eval_define_syntax(expr : Cons, env : Env) : SchemeValue
      name, syntax = build_syntax_rules(expr)
      env.define(name, syntax)
    end

    # Parse (define-syntax name (syntax-rules …)) into {name, SchemeSyntaxRules}
    # without registering — used both by eval_define_syntax and the analyzer's
    # analyze-time macro expansion.
    def build_syntax_rules(expr : Cons) : {String, SchemeSyntaxRules}
      parts = Creme.list_to_a(expr.cdr)
      raise SchemeRuntimeError.new("define-syntax: malformed") unless parts.size == 2
      name = parts[0]
      raise SchemeRuntimeError.new("define-syntax: name must be a symbol") unless name.is_a?(SchemeSym)

      spec = Creme.list_to_a(parts[1])
      raise SchemeRuntimeError.new("define-syntax: expects (syntax-rules (literal...) (pattern template)...)") if spec.empty?
      keyword = spec[0]
      raise SchemeRuntimeError.new("define-syntax: expected syntax-rules") unless keyword.is_a?(SchemeSym) && keyword.name == "syntax-rules"

      literals = Creme.list_to_a(spec[1]).map do |lit|
        raise SchemeRuntimeError.new("syntax-rules: literal must be a symbol") unless lit.is_a?(SchemeSym)
        lit.name
      end

      rules = spec[2..].map do |rule|
        rule_parts = Creme.list_to_a(rule)
        raise SchemeRuntimeError.new("syntax-rules: bad rule") unless rule_parts.size == 2
        {rule_parts[0], rule_parts[1]}
      end

      {name.name, SchemeSyntaxRules.new(name.name, literals, rules)}
    end

    # Finds the first rule whose pattern matches `expr` (the whole call
    # form, keyword position included — match_pattern's `_`/first-symbol
    # handling treats that position as a wildcard, per convention) and
    # returns its instantiated template, ready for the caller to re-analyze
    # (the analyzer expands syntax-rules calls in place).
    private def expand_syntax_rules(syntax : SchemeSyntaxRules, expr : SchemeValue) : SchemeValue
      syntax.rules.each do |pattern, template|
        raise SchemeRuntimeError.new("syntax-rules: pattern must be a list") unless pattern.is_a?(Cons)
        if bindings = Creme.match_pattern(pattern.cdr, expr.as(Cons).cdr, syntax.literals)
          return Creme.instantiate_template(template, bindings)
        end
      end
      raise SchemeRuntimeError.new("#{syntax.name}: no matching syntax-rules clause")
    end
  end
end
