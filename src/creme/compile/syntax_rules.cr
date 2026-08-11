# ===========================================================================
# define-syntax / syntax-rules
#
# A hygienic pattern-matching macro system: literals and `...` ellipsis are
# supported, and a template-introduced identifier can neither capture nor be
# captured by a use-site identifier of the same name. Hygiene is implemented
# as two independent mechanisms applied once per expansion, at expansion
# time — not via a pervasive syntax-object/scope-set representation change:
#
#   1. Binder renaming: every identifier a template introduces as a NEW
#      binding (a `let`/`lambda`/`do`/etc. bound-name slot written literally
#      in the template, never a pattern variable) is alpha-renamed to a
#      fresh, process-unique name, consistently across the whole expansion.
#      See `collect_binders` below.
#   2. Free-reference protection: every identifier a template uses as a free
#      reference (not itself a binder) that resolves, at the MACRO'S OWN
#      definition point, to a special form / global procedure / macro gets a
#      fresh alias name too — registered in Interpreter#@syntax_global_aliases,
#      which the analyzer (analyzer.cr's analyze_cons/analyze_app/analyze_var)
#      consults before its normal scope/env lookup, forcing the reference
#      back to its definition-time meaning no matter what the use site's own
#      local scope contains. See `collect_free_refs`.
#
# Both mechanisms only ever touch fresh, process-unique names the renamer
# itself mints, so neither can affect any other code path. `defmacro` is
# NOT covered by this — it's a separate, deliberately-manual fexpr mechanism
# (its own `gensym`-based capture-avoidance workaround is unchanged) whose
# "template" is arbitrary evaluated code, not a pattern/template pair, so
# this static classification approach doesn't apply to it.
# ===========================================================================

module Creme
  ELLIPSIS = "..."

  # Positionally-recognized auxiliary keywords: never renamed/aliased, since
  # they're matched by literal name (not resolved as bindings) by cond/case/
  # quasiquote/the ellipsis machinery itself. Renaming one of these would
  # silently break any of those forms nested inside a macro template.
  HYGIENE_EXCLUDED = Set{"...", "_", "else", "=>", "unquote", "unquote-splicing", "quasiquote"}

  # One (define-syntax name (syntax-rules (literal...) (pattern template)...))
  # binding. `rules` pairs each pattern with its template; patterns include
  # the macro-name/keyword position (conventionally `_` or the macro name
  # itself), which match_pattern always treats as a wildcard. `env` is the
  # environment active at the macro's OWN definition point (define-syntax/
  # let-syntax/letrec-syntax) — used only to resolve a template's free
  # references for hygiene (mechanism 2 above), mirroring how `Macro`
  # (defmacro) already captures its own definition env.
  class SchemeSyntaxRules
    include SchemeBaseValue
    getter name : String
    getter literals : Array(String)
    getter rules : Array({SchemeValue, SchemeValue})
    getter env : Env

    def initialize(@name : String, @literals : Array(String), @rules : Array({SchemeValue, SchemeValue}), @env : Env)
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
  # `bindings` pass through unchanged. Hygiene (Interpreter#apply_hygiene,
  # below) works by merging binder-rename/free-reference-alias entries
  # into `bindings` BEFORE this runs, as ordinary SchemeSym substitutions —
  # so this function itself needs no hygiene-specific logic at all.
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

  # ---- hygiene: template classification -------------------------------
  #
  # Two-pass, over the raw (pre-substitution) chosen template: Pass 1 finds
  # every literal symbol the template introduces as a NEW binding anywhere
  # in it (regardless of nesting order — collecting the complete set first
  # means Pass 2 can tell "is this reference to one of MY OWN binders" with
  # a simple membership check, with no scope-tracking needed); Pass 2 then
  # collects every remaining literal symbol used as a free reference.
  # Neither pass descends into a template's own `(quote ...)` argument, and
  # both track quasiquote's literal-vs-unquoted regions the same way — a
  # symbol meant to survive as quoted DATA must never be classified either
  # way. Neither pass descends into a nested (syntax-rules ...)/
  # (define-syntax ...) sub-form (its own pattern vars/literals/`...` are a
  # separate scope this template's own classification has no business in).

  private def self.classifiable?(name : String, bindings : Hash(String, SyntaxBinding), literals : Array(String)) : Bool
    !bindings.has_key?(name) && !literals.includes?(name) && !HYGIENE_EXCLUDED.includes?(name)
  end

  private def self.add_binder(sym : SchemeValue, bindings : Hash(String, SyntaxBinding), literals : Array(String), binders : Set(String)) : Nil
    binders << sym.name if sym.is_a?(SchemeSym) && classifiable?(sym.name, bindings, literals)
  end

  # Walks a lambda-style formal list: a bare symbol (all-rest lambda), a
  # proper/dotted list of symbols, or SchemeNil (no params).
  private def self.collect_formal_binders(formals : SchemeValue, bindings : Hash(String, SyntaxBinding), literals : Array(String), binders : Set(String)) : Nil
    case formals
    when SchemeSym
      add_binder(formals, bindings, literals, binders)
    when Cons
      add_binder(formals.car, bindings, literals, binders)
      collect_formal_binders(formals.cdr, bindings, literals, binders)
    else
      # SchemeNil (end of a proper list) — nothing more to add.
    end
  end

  # `((name init) ...)`-shaped let/let*/letrec/letrec* bindings — each
  # clause's name is a binder; its init expression is ordinary code (may
  # itself introduce further nested binders, so it's walked too).
  private def self.collect_let_binders(clauses : SchemeValue, bindings : Hash(String, SyntaxBinding), literals : Array(String), binders : Set(String)) : Nil
    cur = clauses
    while cur.is_a?(Cons)
      clause = cur.car
      if clause.is_a?(Cons)
        add_binder(clause.car, bindings, literals, binders)
        collect_binders(clause.cdr, bindings, literals, binders)
      end
      cur = cur.cdr
    end
  end

  # `((var init step) ...)`-shaped do-bindings — same shape as let-bindings
  # for classification purposes (var is the binder; init/step are code).
  private def self.collect_do_binders(clauses : SchemeValue, bindings : Hash(String, SyntaxBinding), literals : Array(String), binders : Set(String)) : Nil
    collect_let_binders(clauses, bindings, literals, binders)
  end

  # `((formals expr) ...)`-shaped let-values/let*-values bindings — formals
  # is itself a formal list (possibly dotted), expr is ordinary code.
  private def self.collect_let_values_binders(clauses : SchemeValue, bindings : Hash(String, SyntaxBinding), literals : Array(String), binders : Set(String)) : Nil
    cur = clauses
    while cur.is_a?(Cons)
      clause = cur.car
      if clause.is_a?(Cons)
        collect_formal_binders(clause.car, bindings, literals, binders)
        collect_binders(clause.cdr, bindings, literals, binders)
      end
      cur = cur.cdr
    end
  end

  # Pass 1: collect every literal template symbol introduced as a NEW
  # binding by a literally-written lambda/let-family/do/define/case-lambda
  # form anywhere in `template`.
  # ameba:disable Metrics/CyclomaticComplexity
  def self.collect_binders(template : SchemeValue, bindings : Hash(String, SyntaxBinding), literals : Array(String), binders : Set(String)) : Nil
    return unless template.is_a?(Cons)
    return if ellipsis_escape?(template) # verbatim-escaped sub-template: not code, skip entirely

    if (head = template.car).is_a?(SchemeSym)
      rest = template.cdr
      case head.name
      when "quote"
        return
      when "quasiquote"
        return
      when "syntax-rules", "define-syntax"
        return
      when "lambda", "λ"
        if rest.is_a?(Cons)
          collect_formal_binders(rest.car, bindings, literals, binders)
          collect_binders(rest.cdr, bindings, literals, binders)
        end
        return
      when "let", "let*", "letrec", "letrec*"
        if rest.is_a?(Cons)
          first = rest.car
          if first.is_a?(SchemeSym)
            # named let: (let loop ((v init)...) body...)
            add_binder(first, bindings, literals, binders)
            binding_rest = rest.cdr
            if binding_rest.is_a?(Cons)
              collect_let_binders(binding_rest.car, bindings, literals, binders)
              collect_binders(binding_rest.cdr, bindings, literals, binders)
            end
          else
            collect_let_binders(first, bindings, literals, binders)
            collect_binders(rest.cdr, bindings, literals, binders)
          end
        end
        return
      when "do"
        if rest.is_a?(Cons)
          collect_do_binders(rest.car, bindings, literals, binders)
          collect_binders(rest.cdr, bindings, literals, binders)
        end
        return
      when "define"
        if rest.is_a?(Cons)
          target = rest.car
          if target.is_a?(Cons)
            add_binder(target.car, bindings, literals, binders)
            collect_formal_binders(target.cdr, bindings, literals, binders)
          else
            add_binder(target, bindings, literals, binders)
          end
          collect_binders(rest.cdr, bindings, literals, binders)
        end
        return
      when "define-values"
        if rest.is_a?(Cons)
          collect_formal_binders(rest.car, bindings, literals, binders)
          collect_binders(rest.cdr, bindings, literals, binders)
        end
        return
      when "let-values", "let*-values"
        if rest.is_a?(Cons)
          collect_let_values_binders(rest.car, bindings, literals, binders)
          collect_binders(rest.cdr, bindings, literals, binders)
        end
        return
      when "case-lambda"
        cur = rest
        while cur.is_a?(Cons)
          clause = cur.car
          if clause.is_a?(Cons)
            collect_formal_binders(clause.car, bindings, literals, binders)
            collect_binders(clause.cdr, bindings, literals, binders)
          end
          cur = cur.cdr
        end
        return
      end
    end
    collect_binders(template.car, bindings, literals, binders)
    collect_binders(template.cdr, bindings, literals, binders)
  end

  # Pass 2: collect every remaining literal template symbol used as a free
  # reference (not itself a Pass-1 binder, pattern variable, literal, or
  # excluded auxiliary keyword) — quote/quasiquote handled the same
  # skip-literal-data way as Pass 1.
  def self.collect_free_refs(template : SchemeValue, bindings : Hash(String, SyntaxBinding), literals : Array(String), binders : Set(String), free_refs : Set(String)) : Nil
    case template
    when SchemeSym
      name = template.name
      free_refs << name if classifiable?(name, bindings, literals) && !binders.includes?(name)
    when Cons
      return if ellipsis_escape?(template)
      if (head = template.car).is_a?(SchemeSym)
        case head.name
        when "quote"
          return
        when "quasiquote"
          collect_free_refs_qq(template.cdr, bindings, literals, binders, free_refs, 1)
          return
        end
      end
      collect_free_refs(template.car, bindings, literals, binders, free_refs)
      collect_free_refs(template.cdr, bindings, literals, binders, free_refs)
    else
      # literal datum — never classified.
    end
  end

  # Quasiquote-depth-aware free-reference walk: literal (non-unquoted)
  # regions are pure data and are never classified; `unquote`/
  # `unquote-splicing` at the innermost depth re-enters ordinary code mode.
  private def self.collect_free_refs_qq(template : SchemeValue, bindings : Hash(String, SyntaxBinding), literals : Array(String), binders : Set(String), free_refs : Set(String), depth : Int32) : Nil
    return unless template.is_a?(Cons)
    if (head = template.car).is_a?(SchemeSym)
      case head.name
      when "unquote", "unquote-splicing"
        if depth == 1
          arg = template.cdr
          collect_free_refs(arg.car, bindings, literals, binders, free_refs) if arg.is_a?(Cons)
          return
        else
          collect_free_refs_qq(template.cdr, bindings, literals, binders, free_refs, depth - 1)
          return
        end
      when "quasiquote"
        collect_free_refs_qq(template.cdr, bindings, literals, binders, free_refs, depth + 1)
        return
      end
    end
    collect_free_refs_qq(template.car, bindings, literals, binders, free_refs, depth)
    collect_free_refs_qq(template.cdr, bindings, literals, binders, free_refs, depth)
  end

  class Interpreter
    # (define-syntax name (syntax-rules (literal...) (pattern template)...))
    def eval_define_syntax(expr : Cons, env : Env) : SchemeValue
      name, syntax = build_syntax_rules(expr, env)
      env.define(name, syntax)
    end

    # Parse (define-syntax name (syntax-rules …)) into {name, SchemeSyntaxRules}
    # without registering — used both by eval_define_syntax and the analyzer's
    # analyze-time macro expansion. `env` is captured as the macro's own
    # definition environment, used later (only) to resolve a template's free
    # references for hygiene.
    def build_syntax_rules(expr : Cons, env : Env) : {String, SchemeSyntaxRules}
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

      {name.name, SchemeSyntaxRules.new(name.name, literals, rules, env)}
    end

    # Finds the first rule whose pattern matches `expr` (the whole call
    # form, keyword position included — match_pattern's `_`/first-symbol
    # handling treats that position as a wildcard, per convention), applies
    # hygiene (see apply_hygiene), and returns the instantiated template,
    # ready for the caller to re-analyze (the analyzer expands syntax-rules
    # calls in place).
    private def expand_syntax_rules(syntax : SchemeSyntaxRules, expr : SchemeValue) : SchemeValue
      syntax.rules.each do |pattern, template|
        raise SchemeRuntimeError.new("syntax-rules: pattern must be a list") unless pattern.is_a?(Cons)
        if bindings = Creme.match_pattern(pattern.cdr, expr.as(Cons).cdr, syntax.literals)
          return Creme.instantiate_template(template, apply_hygiene(template, bindings, syntax))
        end
      end
      raise SchemeRuntimeError.new("#{syntax.name}: no matching syntax-rules clause")
    end

    # Computes this expansion's hygienic rename/alias entries and merges
    # them into `bindings` as ordinary SchemeSym substitutions — already
    # exactly what instantiate_template's symbol case does, so no change is
    # needed there. Every template-introduced binder gets a fresh,
    # process-unique name (mechanism 1 — see this file's header). Every
    # free reference that resolves, in the macro's OWN definition
    # environment, to a special form/global procedure/macro gets a fresh
    # alias name too, registered in @syntax_global_aliases so the analyzer
    # resolves it back to that definition-time meaning regardless of the
    # use site's own local scope (mechanism 2). An unresolvable free
    # reference is left completely untouched — never renamed, never
    # aliased (the safe default: it might be genuinely free, or a template
    # bug, but either way guessing wrong here would be worse).
    private def apply_hygiene(template : SchemeValue, bindings : Hash(String, SyntaxBinding), syntax : SchemeSyntaxRules) : Hash(String, SyntaxBinding)
      binders = Set(String).new
      free_refs = Set(String).new
      Creme.collect_binders(template, bindings, syntax.literals, binders)
      Creme.collect_free_refs(template, bindings, syntax.literals, binders, free_refs)
      return bindings if binders.empty? && free_refs.empty?

      hygienic = bindings.dup
      binders.each { |name| hygienic[name] = SchemeSym.of(fresh_hygiene_name(name)).as(SyntaxBinding) }
      free_refs.each do |name|
        next unless syntax.env.get?(name) || SPECIAL_FORM_KEYWORDS.has_key?(name)
        # A deliberately non-interned instance (bypassing SchemeSym.of) with
        # the SAME name, marked forced_free_ref — see that field's own doc
        # comment for why this (not a textual rename) is what keeps the
        # written expansion byte-identical for every OTHER consumer while
        # still letting THIS process's own analyzer force definition-time
        # resolution for this one occurrence.
        marked = SchemeSym.new(name)
        marked.forced_free_ref = true
        hygienic[name] = marked.as(SyntaxBinding)
      end
      hygienic
    end

    # One fresh, process-unique identifier per hygienic rename/alias.
    # Shares the same monotonic counter as the user-facing (gensym)
    # builtin (misc.cr) — but a distinct separator ("~" vs. gensym's "__")
    # keeps the two namespaces disjoint even though the counter value
    # itself is shared, so a hygiene rename and a user's own (gensym) call
    # can never produce the same string.
    private def fresh_hygiene_name(original : String) : String
      @gensym_counter += 1
      "#{original}~#{@gensym_counter}"
    end
  end
end
