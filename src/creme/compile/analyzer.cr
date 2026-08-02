# ===========================================================================
# Analyzer: s-expression -> Node AST translation
# ===========================================================================
#
# `analyze` translates a parsed s-expression into the typed Node AST (ast.cr)
# once, so it need not be re-parsed on every evaluation. It runs per top-level
# form, against the live environment, because this interpreter's special-form /
# macro / procedure disambiguation is dynamic (special forms are shadowable
# bindings; macros are defined and used across forms).
#
# Every form becomes a typed Node: a macro call is expanded here at analyze time
# and re-analyzed in place (so the BytecodeCompiler and VM never see a macro);
# a malformed form becomes a ThrowNode that raises only when reached at runtime.

module Creme
  # Compile-time macro environment: names bound to a Macro / SchemeSyntaxRules
  # that the analyzer must expand *during analysis* (local macros from
  # let-syntax / internal define-syntax|defmacro). Parent-chained; the analyzer
  # keeps the current one in @analyzing_macros, pushing a child around each body
  # so local macros don't leak to siblings. Top-level and imported macros are
  # found via the runtime env (env.get?) instead.
  class MacroEnv
    getter parent : MacroEnv?

    def initialize(@parent : MacroEnv? = nil)
      @macros = {} of String => SchemeValue
    end

    def child : MacroEnv
      MacroEnv.new(self)
    end

    def define(name : String, transformer : SchemeValue) : Nil
      @macros[name] = transformer
    end

    def lookup(name : String) : SchemeValue?
      cur : MacroEnv? = self
      while cur
        if v = cur.@macros[name]?
          return v
        end
        cur = cur.parent
      end
      nil
    end
  end

  # Immutable compile-time lexical scope: the identifier names bound at the
  # current point, as a parent-linked chain of frames (one per enclosing
  # compiled lambda — which mirror the runtime call-env chain exactly, since a
  # lambda only compiles when fallback-free and thus introduces no let/letrec
  # frames). `names` are ordered [params…, rest?, internal-defines…] to match
  # the runtime value-slot order; `safe_count` is how many of them (params +
  # rest) sit at fixed, always-valid slot indices and so can be lexically
  # addressed. Used to (a) tell a local from a global special-form keyword, and
  # (b) resolve a reference to a (depth, index) address.
  class AnalyzerScope
    EMPTY = new(nil, [] of String, 0)

    getter parent : AnalyzerScope?
    getter names : Array(String)
    getter safe_count : Int32

    def initialize(@parent : AnalyzerScope?, @names : Array(String), @safe_count : Int32)
    end

    def extend(names : Array(String), safe_count : Int32) : AnalyzerScope
      AnalyzerScope.new(self, names, safe_count)
    end

    def bound?(name : String) : Bool
      cur : AnalyzerScope? = self
      while cur
        return true if cur.names.includes?(name)
        cur = cur.parent
      end
      false
    end

    # (depth, index) if `name` is bound at an addressable (param/rest) slot;
    # nil if unbound OR bound only at a non-addressable slot (an internal
    # define, whose slot appears at runtime only once its define executes).
    def address(name : String) : {Int32, Int32}?
      depth = 0
      cur : AnalyzerScope? = self
      while cur
        idx = cur.names.index(name)
        return idx < cur.safe_count ? {depth, idx} : nil if idx
        cur = cur.parent
        depth += 1
      end
      nil
    end
  end

  class Interpreter
    # Translate one form into a Node, resolving free head symbols against `env`
    # (the live evaluation environment) to detect special forms. `pos` is a
    # fallback position for `sexpr`s that don't carry their own — a bare
    # SchemeSym/literal value has no position of its own (only the Cons cell
    # that held it does, per SourcePos being a Cons-only property; see
    # value/values.cr), so a caller that's iterating a raw Cons chain (and so
    # has each cell's own pos in hand) can pass it through here rather than it
    # being silently lost. A Cons `sexpr` ignores `pos` and uses its own.
    def analyze(sexpr : SchemeValue, env : Env, scope : AnalyzerScope = AnalyzerScope::EMPTY, pos : SourcePos? = nil) : Node
      case sexpr
      when SchemeSym
        analyze_var(sexpr.name, scope, pos)
      when Cons
        analyze_cons(sexpr, env, scope)
      else
        LiteralNode.new(sexpr, pos)
      end
    end

    # Resolve a variable reference to a lexical address where possible: a
    # param/rest local becomes a LocalRefNode (direct slot read); a free
    # variable becomes a GlobalRefNode (version-cached global lookup); a bound-
    # but-not-addressable name (an internal define) stays a name-keyed VarRef.
    private def analyze_var(name : String, scope : AnalyzerScope, pos : SourcePos? = nil) : Node
      if addr = scope.address(name)
        LocalRefNode.new(addr[0], addr[1], name, pos)
      elsif scope.bound?(name)
        VarRefNode.new(name, pos)
      else
        GlobalRefNode.new(icecreme_global_name(name, scope), pos)
      end
    end

    # Only used by IcecremeEmitter's per-library second analyze pass (see
    # `icecreme_rename`'s own doc comment on Interpreter) to qualify a library's
    # own internal (non-exported) top-level bindings so they can't collide
    # with another library's same-named internal helper in icecreme's single
    # flat, name-interned global table (icecreme has no per-library namespacing
    # of its own — see icecreme/vm.c's cvm_global_intern). `scope.bound?(name)`
    # is false only for a genuinely free (library-top-level-or-outer)
    # reference — a lexically local/internal-define name (already added to
    # `scope` by whatever body prepass introduced it) must never be
    # renamed here, since it isn't actually going to become an icecreme global at
    # all. nil `@icecreme_rename` (the overwhelmingly common case — real
    # interpreter execution never sets this) makes this a plain no-op.
    private def icecreme_global_name(name : String, scope : AnalyzerScope) : String
      return name if scope.bound?(name)
      (rename = @icecreme_rename) ? rename[name]? || name : name
    end

    private def analyze_cons(form : Cons, env : Env, scope : AnalyzerScope) : Node
      head = form.car
      if head.is_a?(SchemeSym) && !scope.bound?(head.name)
        # Macro (expanded at analyze time): a local macro (let-syntax / internal
        # define-syntax|defmacro) from @analyzing_macros, or a global/imported
        # macro from the runtime env. Expand and re-analyze the expansion.
        if m = @analyzing_macros.lookup(head.name)
          return expand_and_analyze(m, form, env, scope)
        end
        binding = env.get?(head.name)
        if binding.is_a?(SchemeSpecialForm)
          return analyze_special_form(binding.kind, form, env, scope)
        elsif binding.is_a?(Macro) || binding.is_a?(SchemeSyntaxRules)
          return expand_and_analyze(binding, form, env, scope)
        elsif binding.nil? && (kind = SPECIAL_FORM_KEYWORDS[head.name]?)
          # A keyword not bound as a marker in this env (e.g. a fresh library
          # env, whose chain lacks the special-form markers) is still syntax —
          # fall back to the SPECIAL_FORM_KEYWORDS table for an unbound head.
          return analyze_special_form(kind, form, env, scope)
        end
      end
      analyze_app(form, env, scope)
    end

    # Expand a macro call and analyze the result (looping until a non-macro
    # form), with a depth guard against a runaway/self-expanding macro.
    private def expand_and_analyze(macro_def : SchemeValue, form : Cons, env : Env, scope : AnalyzerScope) : Node
      @macro_expand_depth += 1
      begin
        raise SchemeRuntimeError.new("macro expansion too deep (possible infinite macro)") if @macro_expand_depth > 100_000
        expansion = macro_def.is_a?(SchemeSyntaxRules) ? expand_syntax_rules(macro_def, form) : expand_defmacro(macro_def.as(Macro), form)
        analyze(expansion, env, scope)
      ensure
        @macro_expand_depth -= 1
      end
    end

    # The head keyword of a special form (always a symbol — that's how dispatch
    # got here). Used to interpolate the exact keyword into a malformed-form
    # error (e.g. letrec vs letrec*).
    private def kw(form : Cons) : String
      (h = form.car).is_a?(SchemeSym) ? h.name : ""
    end

    # A malformed form: raise `message` at EVAL time, not analyze time, so the
    # error surfaces only when (if) the form is actually reached.
    private def malformed(message : String, form : Cons) : Node
      ThrowNode.new(message, form.pos)
    end

    # Returns a typed node for every special form. A malformed form becomes a
    # ThrowNode that raises at eval time.
    # ameba:disable Metrics/CyclomaticComplexity
    private def analyze_special_form(kind : SpecialForm, form : Cons, env : Env, scope : AnalyzerScope) : Node
      case kind
      when SpecialForm::Quote
        args = Creme.list_to_a(form.cdr)
        return malformed("quote: expects 1 argument", form) unless args.size == 1
        LiteralNode.new(args[0], form.pos)
      when SpecialForm::If               then analyze_if(form, env, scope)
      when SpecialForm::Begin            then analyze_begin(form, env, scope)
      when SpecialForm::Lambda           then analyze_lambda(form, env, scope)
      when SpecialForm::Define           then analyze_define(form, env, scope)
      when SpecialForm::Let              then analyze_let(form, env, scope)
      when SpecialForm::LetStar          then analyze_let_star(form, env, scope)
      when SpecialForm::Letrec           then analyze_letrec(form, env, scope)
      when SpecialForm::SetBang          then analyze_set(form, env, scope)
      when SpecialForm::When             then analyze_when(form, env, scope, negate: false)
      when SpecialForm::Unless           then analyze_when(form, env, scope, negate: true)
      when SpecialForm::And              then analyze_and(form, env, scope)
      when SpecialForm::Or               then analyze_or(form, env, scope)
      when SpecialForm::Cond             then analyze_cond(form, env, scope)
      when SpecialForm::Case             then analyze_case(form, env, scope)
      when SpecialForm::Do               then analyze_do(form, env, scope)
      when SpecialForm::CaseLambda       then analyze_case_lambda(form, env, scope)
      when SpecialForm::DefineValues     then analyze_define_values(form, env, scope)
      when SpecialForm::LetValues        then analyze_let_values(form, env, scope, sequential: false)
      when SpecialForm::LetStarValues    then analyze_let_values(form, env, scope, sequential: true)
      when SpecialForm::CondExpand       then analyze_cond_expand(form, env, scope)
      when SpecialForm::Include          then analyze_include(form, env, scope)
      when SpecialForm::Import           then HelperFormNode.new(HelperForm::Import, form, form.pos)
      when SpecialForm::DefineLibrary    then HelperFormNode.new(HelperForm::DefineLibrary, form, form.pos)
      when SpecialForm::DefineRecordType then HelperFormNode.new(HelperForm::DefineRecordType, form, form.pos)
      when SpecialForm::Guard            then analyze_guard(form, env, scope)
      when SpecialForm::Parameterize     then analyze_parameterize(form, env, scope)
      when SpecialForm::Delay            then analyze_delay(form, env, scope)
      when SpecialForm::Quasiquote       then analyze_quasiquote(form, env, scope)
      when SpecialForm::DefineSyntax     then analyze_define_syntax(form, env, scope)
      when SpecialForm::Defmacro         then analyze_defmacro(form, env, scope)
      when SpecialForm::LetSyntax        then analyze_let_syntax(form, env, scope)
      else
        # Only Unquote/UnquoteSplicing reach here (they map to SpecialForm::Unquote).
        malformed("#{kw(form)}: not valid outside quasiquote", form)
      end
    end

    # define-syntax: build the macro, register it in the compile-time macro
    # scope (so later forms in this body expand it), and emit a node that
    # registers it in the runtime env too (needed for macro-as-value / errors).
    private def analyze_define_syntax(form : Cons, env : Env, scope : AnalyzerScope) : Node
      begin
        name, syntax = build_syntax_rules(form)
        @analyzing_macros.define(name, syntax)
      rescue SchemeError
        # Malformed: skip registration. The emitted node calls eval_define_syntax
        # at eval time, which re-parses and raises the exact message (preserving
        # eval-time timing for a malformed form in an unreached position).
      end
      HelperFormNode.new(HelperForm::DefineSyntax, form, form.pos)
    end

    private def analyze_defmacro(form : Cons, env : Env, scope : AnalyzerScope) : Node
      begin
        # Capture @global as the macro's env: for an internal defmacro the runtime
        # frame doesn't exist at analyze time (documented limitation — a body
        # referencing an enclosing lexical var is unsupported).
        name, mac = build_macro(form, @global)
        @analyzing_macros.define(name, mac)
      rescue SchemeError
        # Malformed: eval_defmacro raises the exact message at eval time.
      end
      HelperFormNode.new(HelperForm::Defmacro, form, form.pos)
    end

    # let-syntax/letrec-syntax: register the local macros in a pushed macro
    # scope, then analyze the body as an empty-binding let (a fresh frame that
    # isolates internal defines and matches the analysis scope). At runtime the
    # macros are gone — all their uses were expanded at analyze time.
    private def analyze_let_syntax(form : Cons, env : Env, scope : AnalyzerScope) : Node
      # Mirror eval_let_syntax's validation/messages exactly (the head keyword is
      # always reported as "let-syntax", even for letrec-syntax).
      rest = form.cdr
      return malformed("let-syntax: malformed", form) unless rest.is_a?(Cons)
      return malformed("improper list: #{rest.car.write_string}", form) unless proper_list?(rest.car)
      saved = @analyzing_macros
      @analyzing_macros = saved.child
      begin
        Creme.list_to_a(rest.car).each do |binding|
          return malformed("let-syntax: bad binding", form) unless binding.is_a?(Cons)
          name, syntax = build_syntax_rules(Cons.new(SchemeSym.of("define-syntax"), binding))
          @analyzing_macros.define(name, syntax)
        end
        analyze_plain_let(form, Cons.new(NIL, rest.cdr).as(Cons), env, scope)
      rescue ex : SchemeError
        # A build_syntax_rules failure raises the same message eval_define_syntax
        # would; defer it to eval time (matching today's timing).
        malformed(ex.message || "let-syntax: malformed", form)
      ensure
        @analyzing_macros = saved
      end
    end

    private def analyze_delay(form : Cons, env : Env, scope : AnalyzerScope) : Node
      args = Creme.list_to_a(form.cdr)
      return malformed("#{kw(form)}: expects 1 argument", form) unless args.size == 1
      DelayNode.new(analyze(args[0], env, scope), form.pos)
    end

    private def analyze_quasiquote(form : Cons, env : Env, scope : AnalyzerScope) : Node
      args = Creme.list_to_a(form.cdr)
      return malformed("quasiquote: expects 1 argument", form) unless args.size == 1
      QuasiquoteNode.new(build_qq(args[0], env, scope, 1), form.pos)
    end

    # Mirror of expand_qq (interpreter.cr) that pre-analyzes unquote holes into
    # a QQTemplate tree instead of evaluating them.
    # ameba:disable Metrics/CyclomaticComplexity
    private def build_qq(tmpl : SchemeValue, env : Env, scope : AnalyzerScope, depth : Int32) : QQTemplate
      return build_qq_vector(tmpl, env, scope, depth) if tmpl.is_a?(SchemeVector)
      return QQConst.new(tmpl) unless tmpl.is_a?(Cons)
      head = tmpl.car
      if head.is_a?(SchemeSym)
        case head.name
        when "unquote"
          inner = Creme.list_to_a(tmpl.cdr)
          raise SchemeRuntimeError.new("unquote: expects 1 argument") unless inner.size == 1
          return QQHole.new(analyze(inner[0], env, scope)) if depth == 1
          return QQList.new([QQConst.new(SchemeSym.of("unquote")).as(QQTemplate), build_qq(inner[0], env, scope, depth - 1)], QQConst.new(NIL))
        when "quasiquote"
          inner = Creme.list_to_a(tmpl.cdr)
          raise SchemeRuntimeError.new("quasiquote: expects 1 argument") unless inner.size == 1
          return QQList.new([QQConst.new(SchemeSym.of("quasiquote")).as(QQTemplate), build_qq(inner[0], env, scope, depth + 1)], QQConst.new(NIL))
        end
      end
      items = [] of QQTemplate
      cur : SchemeValue = tmpl
      tail : QQTemplate = QQConst.new(NIL)
      while cur.is_a?(Cons)
        elem = cur.car
        if elem.is_a?(Cons) && (eh = elem.car).is_a?(SchemeSym) && eh.name == "unquote-splicing" && depth == 1
          spliced = Creme.list_to_a(elem.cdr)
          raise SchemeRuntimeError.new("unquote-splicing: expects 1 argument") unless spliced.size == 1
          items << QQSpliceItem.new(analyze(spliced[0], env, scope))
          cur = cur.cdr
        elsif elem.is_a?(Cons) && (eh2 = elem.car).is_a?(SchemeSym) && eh2.name == "unquote-splicing"
          inner = Creme.list_to_a(elem.cdr)
          items << QQList.new([QQConst.new(SchemeSym.of("unquote-splicing")).as(QQTemplate), build_qq(inner[0], env, scope, depth - 1)], QQConst.new(NIL))
          cur = cur.cdr
        else
          cdr = cur.cdr
          if cdr.is_a?(Cons) && (ch = cdr.car).is_a?(SchemeSym) && ch.name == "unquote" && depth == 1
            items << build_qq(elem, env, scope, depth)
            uq = Creme.list_to_a(cdr.cdr)
            raise SchemeRuntimeError.new("unquote: expects 1 argument") unless uq.size == 1
            tail = QQHole.new(analyze(uq[0], env, scope))
            cur = NIL
            break
          end
          items << build_qq(elem, env, scope, depth)
          cur = cur.cdr
        end
      end
      # Improper tail (e.g. `(a b . c)): expand it as a template too.
      tail = build_qq(cur, env, scope, depth) unless cur.is_a?(SchemeNil)
      QQList.new(items, tail)
    end

    private def build_qq_vector(tmpl : SchemeVector, env : Env, scope : AnalyzerScope, depth : Int32) : QQTemplate
      items = [] of QQTemplate
      tmpl.value.each do |elem|
        if elem.is_a?(Cons) && (eh = elem.car).is_a?(SchemeSym) && eh.name == "unquote-splicing" && depth == 1
          spliced = Creme.list_to_a(elem.cdr)
          raise SchemeRuntimeError.new("unquote-splicing: expects 1 argument") unless spliced.size == 1
          items << QQSpliceItem.new(analyze(spliced[0], env, scope))
        elsif elem.is_a?(Cons) && (eh2 = elem.car).is_a?(SchemeSym) && eh2.name == "unquote-splicing"
          inner = Creme.list_to_a(elem.cdr)
          items << QQList.new([QQConst.new(SchemeSym.of("unquote-splicing")).as(QQTemplate), build_qq(inner[0], env, scope, depth - 1)], QQConst.new(NIL))
        else
          items << build_qq(elem, env, scope, depth)
        end
      end
      QQVector.new(items)
    end

    private def analyze_guard(form : Cons, env : Env, scope : AnalyzerScope) : Node
      # Spec malformation is validated up front (eval_guard raises before running
      # the body); a malformed CLAUSE is deferred (eval_guard inspects clauses
      # only if the body raises AND the clause is reached).
      parts = Creme.list_to_a(form.cdr)
      return malformed("guard: malformed", form) if parts.empty?
      return malformed("improper list: #{parts[0].write_string}", form) unless proper_list?(parts[0])
      spec = Creme.list_to_a(parts[0])
      return malformed("guard: malformed clause spec", form) if spec.empty?
      return malformed("guard: variable must be a symbol", form) unless (v = spec[0]).is_a?(SchemeSym)
      # Clauses see the condition variable (a fresh handler frame, slot 0).
      clause_scope = scope.extend([v.name], 1)
      clauses = spec[1..].map { |clause| analyze_cond_clause(clause, env, clause_scope) || throw_cond_clause(clause, "guard") }
      body = parts[1..].map { |sub| analyze(sub, env, scope) }
      GuardNode.new(v.name, clauses, body, form.pos)
    end

    # A malformed cond/guard clause as a deferred-throw CondClause: raises only
    # when evaluation reaches it (a clause is validated only once reached).
    private def throw_cond_clause(clause : SchemeValue, who : String) : CondClause
      msg = proper_list?(clause) ? "#{who}: empty clause" : "improper list: #{clause.write_string}"
      CondClause.new(nil, [] of Node, nil, false, msg)
    end

    # A malformed case clause as a deferred-throw CaseClause (see above).
    private def throw_case_clause(clause : SchemeValue) : CaseClause
      msg = if !proper_list?(clause)
              "improper list: #{clause.write_string}"
            elsif (parts = Creme.list_to_a(clause)).empty?
              "case: empty clause"
            elsif !((t = parts[0]).is_a?(SchemeSym) && t.name == "else") && !proper_list?(parts[0])
              "improper list: #{parts[0].write_string}" # datum list is improper
            else
              "case: empty clause"
            end
      CaseClause.new(nil, [] of Node, nil, false, msg)
    end

    private def analyze_parameterize(form : Cons, env : Env, scope : AnalyzerScope) : Node
      parts = Creme.list_to_a(form.cdr)
      return malformed("parameterize: malformed", form) if parts.empty?
      return malformed("improper list: #{parts[0].write_string}", form) unless proper_list?(parts[0])
      bindings = [] of ParamBinding
      Creme.list_to_a(parts[0]).each do |binding|
        bp = Creme.list_to_a(binding)
        return malformed("parameterize: bad binding", form) unless bp.size == 2
        bindings << ParamBinding.new(analyze(bp[0], env, scope), analyze(bp[1], env, scope))
      end
      body = parts[1..].map { |sub| analyze(sub, env, scope) }
      ParameterizeNode.new(bindings, body, form.pos)
    end

    # cond-expand is resolved at analyze time (features/@libraries are known):
    # the first matching clause's body is analyzed inline into a BeginNode.
    private def analyze_cond_expand(form : Cons, env : Env, scope : AnalyzerScope) : Node
      return malformed("improper list: #{form.cdr.write_string}", form) unless proper_list?(form.cdr)
      Creme.list_to_a(form.cdr).each do |clause|
        return malformed("improper list: #{clause.write_string}", form) unless proper_list?(clause)
        parts = Creme.list_to_a(clause)
        return malformed("cond-expand: bad clause", form) if parts.empty?
        req = parts[0]
        matched = (req.is_a?(SchemeSym) && req.name == "else") || cond_expand_matches?(req)
        next unless matched
        return BeginNode.new(parts[1..].map { |sub| analyze(sub, env, scope) }, form.pos)
      end
      BeginNode.new([] of Node, form.pos) # no clause matched -> NIL
    end

    # include splices file contents at the inclusion point: read + parse now
    # (at analyze time, so the forms are analyzed in this lexical scope) and
    # analyze them inline into a BeginNode. @load_dirs is set during evaluation
    # (run_file/include), which is also when top-level forms are analyzed.
    private def analyze_include(form : Cons, env : Env, scope : AnalyzerScope) : Node
      forms = eval_include(Creme.list_to_a(form.cdr), fold_case: form.car.as(SchemeSym).name == "include-ci")
      BeginNode.new(forms.map { |sub| analyze(sub, env, scope) }, form.pos)
    end

    private def analyze_do(form : Cons, env : Env, scope : AnalyzerScope) : Node
      parts = Creme.list_to_a(form.cdr)
      return malformed("do: expects bindings and a test clause", form) unless parts.size >= 2
      return malformed("improper list: #{parts[0].write_string}", form) unless proper_list?(parts[0])
      names = [] of String
      inits = [] of SchemeValue
      steps_raw = [] of SchemeValue?
      Creme.list_to_a(parts[0]).each do |binding|
        bp = Creme.list_to_a(binding)
        return malformed("do: bad binding", form) unless bp.size == 2 || bp.size == 3
        return malformed("do: binding name must be symbol", form) unless (n = bp[0]).is_a?(SchemeSym)
        names << n.name
        inits << bp[1]
        steps_raw << (bp.size == 3 ? bp[2] : nil)
      end
      return malformed("improper list: #{parts[1].write_string}", form) unless proper_list?(parts[1])
      test_clause = Creme.list_to_a(parts[1])
      return malformed("do: empty test clause", form) if test_clause.empty?
      inner = scope.extend(names, names.size)
      init_nodes = inits.map { |sub| analyze(sub, env, scope) } # inits in OUTER scope
      step_nodes, test_node, result_nodes, command_nodes = with_child_macro_scope do
        {
          steps_raw.map { |sub| sub ? analyze(sub, env, inner).as(Node) : nil },
          analyze(test_clause[0], env, inner),
          test_clause[1..].map { |sub| analyze(sub, env, inner) },
          parts[2..].map { |sub| analyze(sub, env, inner) },
        }
      end
      DoNode.new(names, init_nodes, step_nodes, test_node, result_nodes, command_nodes, form.pos)
    end

    private def analyze_set(form : Cons, env : Env, scope : AnalyzerScope) : Node
      args = Creme.list_to_a(form.cdr)
      return malformed("set!: expects 2 arguments", form) unless args.size == 2
      return malformed("set!: first argument must be a symbol", form) unless (n = args[0]).is_a?(SchemeSym)
      SetBangNode.new(icecreme_global_name(n.name, scope), analyze(args[1], env, scope), form.pos)
    end

    private def analyze_when(form : Cons, env : Env, scope : AnalyzerScope, negate : Bool) : Node
      return malformed("improper list: #{form.cdr.write_string}", form) unless proper_list?(form.cdr)
      args = Creme.list_to_a(form.cdr)
      return malformed("#{kw(form)}: expects a condition", form) if args.empty?
      test = analyze(args[0], env, scope)
      body = args[1..].map { |sub| analyze(sub, env, scope) }
      WhenNode.new(test, body, negate, form.pos)
    end

    private def analyze_and(form : Cons, env : Env, scope : AnalyzerScope) : Node
      return malformed("improper list: #{form.cdr.write_string}", form) unless proper_list?(form.cdr)
      AndNode.new(analyze_seq_with_pos(form.cdr, env, scope), form.pos)
    end

    private def analyze_or(form : Cons, env : Env, scope : AnalyzerScope) : Node
      return malformed("improper list: #{form.cdr.write_string}", form) unless proper_list?(form.cdr)
      OrNode.new(analyze_seq_with_pos(form.cdr, env, scope), form.pos)
    end

    private def analyze_let_star(form : Cons, env : Env, scope : AnalyzerScope) : Node
      rest = form.cdr
      return malformed("let*: malformed", form) unless rest.is_a?(Cons)
      parsed = parse_let_bindings_or_msg(rest.car, "let*")
      return malformed(parsed, form) if parsed.is_a?(String)
      names, inits = parsed
      raw_body = Creme.list_to_a(rest.cdr) # empty body allowed -> evaluates inits, yields NIL
      # init_i sees names[0..i-1] in the single let* frame (grow the frame per
      # init); the body sees all names + internal defines.
      init_nodes = inits.map_with_index { |init, i| analyze(init, env, scope.extend(names[0, i], i)) }
      body_scope = scope.extend(names + internal_define_names(raw_body), names.size)
      body = with_child_macro_scope { raw_body.map { |sub| analyze(sub, env, body_scope) } }
      LetStarNode.new(names, init_nodes, body, form.pos)
    end

    private def analyze_letrec(form : Cons, env : Env, scope : AnalyzerScope) : Node
      rest = form.cdr
      return malformed("#{kw(form)}: malformed", form) unless rest.is_a?(Cons)
      parsed = parse_let_bindings_or_msg(rest.car, kw(form))
      return malformed(parsed, form) if parsed.is_a?(String)
      names, inits = parsed
      raw_body = Creme.list_to_a(rest.cdr) # empty body allowed -> evaluates inits, yields NIL
      # All names bound up front (one frame), so inits AND body see them all.
      inner = scope.extend(names + internal_define_names(raw_body), names.size)
      init_nodes = inits.map { |init| analyze(init, env, inner) }
      body = with_child_macro_scope { raw_body.map { |sub| analyze(sub, env, inner) } }
      LetrecNode.new(names, init_nodes, body, form.pos)
    end

    private def analyze_cond(form : Cons, env : Env, scope : AnalyzerScope) : Node
      return malformed("improper list: #{form.cdr.write_string}", form) unless proper_list?(form.cdr)
      clauses = Creme.list_to_a(form.cdr).map do |clause|
        analyze_cond_clause(clause, env, scope) || throw_cond_clause(clause, "cond")
      end
      CondNode.new(clauses, form.pos)
    end

    private def analyze_cond_clause(clause : SchemeValue, env : Env, scope : AnalyzerScope) : CondClause?
      return nil unless proper_list?(clause)
      parts = Creme.list_to_a(clause)
      return nil if parts.empty?
      test = parts[0]
      if test.is_a?(SchemeSym) && test.name == "else"
        CondClause.new(nil, parts[1..].map { |sub| analyze(sub, env, scope) }, nil, true)
      elsif parts.size == 3 && (arrow = parts[1]).is_a?(SchemeSym) && arrow.name == "=>"
        CondClause.new(analyze(test, env, scope), [] of Node, analyze(parts[2], env, scope), false)
      else
        CondClause.new(analyze(test, env, scope), parts[1..].map { |sub| analyze(sub, env, scope) }, nil, false)
      end
    end

    private def analyze_case(form : Cons, env : Env, scope : AnalyzerScope) : Node
      return malformed("improper list: #{form.cdr.write_string}", form) unless proper_list?(form.cdr)
      parts = Creme.list_to_a(form.cdr)
      return malformed("case: expects a key expression", form) if parts.empty?
      key = analyze(parts[0], env, scope)
      clauses = parts[1..].map do |clause|
        analyze_case_clause(clause, env, scope) || throw_case_clause(clause)
      end
      CaseNode.new(key, clauses, form.pos)
    end

    private def analyze_case_clause(clause : SchemeValue, env : Env, scope : AnalyzerScope) : CaseClause?
      return nil unless proper_list?(clause)
      parts = Creme.list_to_a(clause)
      return nil if parts.empty?
      test = parts[0]
      is_else = test.is_a?(SchemeSym) && test.name == "else"
      datums = is_else ? nil : (proper_list?(test) ? Creme.list_to_a(test) : return nil)
      if parts.size == 3 && (arrow = parts[1]).is_a?(SchemeSym) && arrow.name == "=>"
        CaseClause.new(datums, [] of Node, analyze(parts[2], env, scope), is_else)
      else
        CaseClause.new(datums, parts[1..].map { |sub| analyze(sub, env, scope) }, nil, is_else)
      end
    end

    private def analyze_if(form : Cons, env : Env, scope : AnalyzerScope) : Node
      nodes = analyze_seq_with_pos(form.cdr, env, scope)
      return malformed("if: expects 2 or 3 arguments", form) unless nodes.size == 2 || nodes.size == 3
      IfNode.new(nodes[0], nodes[1], nodes.size == 3 ? nodes[2] : nil, form.pos)
    end

    private def analyze_begin(form : Cons, env : Env, scope : AnalyzerScope) : Node
      return malformed("improper list: #{form.cdr.write_string}", form) unless proper_list?(form.cdr)
      body = analyze_seq_with_pos(form.cdr, env, scope)
      BeginNode.new(body, form.pos)
    end

    private def analyze_lambda(form : Cons, env : Env, scope : AnalyzerScope) : Node
      rest = form.cdr
      return malformed("lambda: malformed", form) unless rest.is_a?(Cons)
      result = build_lambda_node(rest.car, Creme.list_to_a(rest.cdr), "lambda", env, scope, form.pos, "lambda: empty body")
      result.is_a?(String) ? malformed(result, form) : result
    end

    # Build a LambdaNode from formals + body, or an error-message String if the
    # form is malformed (empty body -> `empty_body_msg`; bad formals -> the exact
    # message the raising `parse_formals` produces). Every well-formed body
    # compiles to typed nodes, so constant-space tail recursion is preserved:
    # the tail form is always a node the trampoline can loop on.
    private def build_lambda_node(formals : SchemeValue, raw_body : Array(SchemeValue), name : String,
                                  env : Env, scope : AnalyzerScope, pos : SourcePos?, empty_body_msg : String) : LambdaNode | String
      return empty_body_msg if raw_body.empty?
      begin
        params, rparam = parse_formals(formals)
      rescue ex : SchemeError
        return ex.message || "bad formal parameter"
      end
      body_nodes = analyze_body(params, rparam, raw_body, env, scope)
      LambdaNode.new(params, rparam, body_nodes, raw_body, name, pos)
    end

    private def analyze_case_lambda(form : Cons, env : Env, scope : AnalyzerScope) : Node
      clauses_raw = Creme.list_to_a(form.cdr)
      return malformed("case-lambda: expects at least 1 clause", form) if clauses_raw.empty?
      clauses = [] of LambdaNode
      clauses_raw.each do |clause|
        return malformed("case-lambda: malformed clause", form) unless clause.is_a?(Cons)
        ln = build_lambda_node(clause.car, Creme.list_to_a(clause.cdr), "case-lambda", env, scope, form.pos, "lambda: empty body")
        return malformed(ln, form) if ln.is_a?(String)
        clauses << ln
      end
      CaseLambdaNode.new(clauses, form.pos)
    end

    private def analyze_define_values(form : Cons, env : Env, scope : AnalyzerScope) : Node
      parts = Creme.list_to_a(form.cdr)
      return malformed("define-values: malformed", form) unless parts.size == 2
      begin
        params, rparam = parse_formals(parts[0])
      rescue ex : SchemeError
        return malformed(ex.message || "bad formals", form)
      end
      DefineValuesNode.new(params, rparam, analyze(parts[1], env, scope), form.pos)
    end

    private def analyze_let_values(form : Cons, env : Env, scope : AnalyzerScope, sequential : Bool) : Node
      who = sequential ? "let*-values" : "let-values"
      rest = form.cdr
      return malformed("#{who}: malformed", form) unless rest.is_a?(Cons)
      return malformed("improper list: #{rest.car.write_string}", form) unless proper_list?(rest.car)
      raw_body = Creme.list_to_a(rest.cdr) # empty body is allowed (evaluates producers, yields NIL)
      binders = [] of LetValuesBinder
      accumulated = [] of String # names bound so far (one shared frame)
      Creme.list_to_a(rest.car).each do |binding|
        bp = Creme.list_to_a(binding)
        return malformed("#{who}: bad binding", form) unless bp.size == 2
        begin
          params, rparam = parse_formals(bp[0])
        rescue ex : SchemeError
          return malformed(ex.message || "bad formals", form)
        end
        # let*-values: producer sees names bound by earlier clauses (same frame).
        prod_scope = sequential ? scope.extend(accumulated.dup, accumulated.size) : scope
        binders << LetValuesBinder.new(params, rparam, analyze(bp[1], env, prod_scope))
        accumulated.concat(params)
        accumulated << rparam if rparam
      end
      body_scope = scope.extend(accumulated + internal_define_names(raw_body), accumulated.size)
      body = raw_body.map { |sub| analyze(sub, env, body_scope) }
      LetValuesNode.new(binders, body, sequential, form.pos)
    end

    private def analyze_define(form : Cons, env : Env, scope : AnalyzerScope) : Node
      rest = form.cdr
      return malformed("define: malformed", form) unless rest.is_a?(Cons)
      target = rest.car
      case target
      when SchemeSym
        body = Creme.list_to_a(rest.cdr)
        return malformed("define: expects 1 value expression", form) if body.size > 1
        val = body.empty? ? LiteralNode.new(NIL).as(Node) : analyze(body[0], env, scope)
        # (define f (lambda ...)) names the anonymous lambda after its
        # binding, same as the (define (f ...) ...) shorthand just below —
        # only when it's still carrying analyze_lambda's generic default,
        # so an already-named/nested lambda (e.g. one that itself shadows
        # a name via its own shorthand define) is never renamed.
        val.name = target.name if val.is_a?(LambdaNode) && val.name == "lambda"
        DefineNode.new(icecreme_global_name(target.name, scope), val, form.pos)
      when Cons
        fname = target.car
        return malformed("define: function name must be a symbol", form) unless fname.is_a?(SchemeSym)
        lam = build_lambda_node(target.cdr, Creme.list_to_a(rest.cdr), fname.name, env, scope, form.pos, "define: function body is empty")
        lam.is_a?(String) ? malformed(lam, form) : DefineNode.new(icecreme_global_name(fname.name, scope), lam, form.pos)
      else
        malformed("define: bad target #{target.write_string}", form)
      end
    end

    private def analyze_let(form : Cons, env : Env, scope : AnalyzerScope) : Node
      rest = form.cdr
      return malformed("let: malformed", form) unless rest.is_a?(Cons)
      first = rest.car
      if first.is_a?(SchemeSym)
        analyze_named_let(form, first.name, rest.cdr, env, scope)
      else
        analyze_plain_let(form, rest, env, scope)
      end
    end

    private def analyze_plain_let(form : Cons, rest : Cons, env : Env, scope : AnalyzerScope) : Node
      parsed = parse_let_bindings_or_msg(rest.car, "let")
      return malformed(parsed, form) if parsed.is_a?(String)
      names, inits = parsed
      raw_body = Creme.list_to_a(rest.cdr) # empty body allowed -> evaluates inits, yields NIL
      # inits evaluated in the OUTER scope; body sees `names` at fixed slots.
      init_nodes = inits.map { |init| analyze(init, env, scope) }
      body_scope = scope.extend(names + internal_define_names(raw_body), names.size)
      body = with_child_macro_scope { raw_body.map { |sub| analyze(sub, env, body_scope) } }
      LetNode.new(names, init_nodes, body, form.pos)
    end

    private def analyze_named_let(form : Cons, loop_name : String, rest : SchemeValue, env : Env, scope : AnalyzerScope) : Node
      return malformed("let: malformed", form) unless rest.is_a?(Cons)
      parsed = parse_let_bindings_or_msg(rest.car, "let")
      return malformed(parsed, form) if parsed.is_a?(String)
      params, inits = parsed
      raw_body = Creme.list_to_a(rest.cdr)
      # Named let (unlike plain let) requires a non-empty body.
      return malformed("let: named let body is empty", form) if raw_body.empty?
      init_nodes = inits.map { |init| analyze(init, env, scope) }
      # Body scope: an outer frame binding `loop_name`, then the params frame.
      closure_scope = scope.extend([loop_name], 1)
      body_scope = closure_scope.extend(params + internal_define_names(raw_body), params.size)
      body = with_child_macro_scope { raw_body.map { |sub| analyze(sub, env, body_scope) } }
      NamedLetNode.new(loop_name, params, init_nodes, body, raw_body, form.pos)
    end

    # Parse ((name init)...) into {names, inits}, or a malformed-form error
    # message (`who` being the let variant, e.g. "let"/"let*"/"letrec") if the
    # binding list is malformed.
    private def parse_let_bindings_or_msg(spec : SchemeValue, who : String) : {Array(String), Array(SchemeValue)} | String
      return "improper list: #{spec.write_string}" unless proper_list?(spec)
      names = [] of String
      inits = [] of SchemeValue
      Creme.list_to_a(spec).each do |binding|
        return "improper list: #{binding.write_string}" unless proper_list?(binding)
        parts = Creme.list_to_a(binding)
        return "#{who}: bad binding" unless parts.size == 2
        return "#{who}: binding name must be symbol" unless (n = parts[0]).is_a?(SchemeSym)
        names << n.name
        inits << parts[1]
      end
      {names, inits}
    end

    # Analyzes each element of a raw Cons chain, unlike `Creme.list_to_a(list)
    # .map { |sub| analyze(sub, env, scope) }` — that discards each cell's own
    # `.pos` before `analyze` ever sees the element, which is why a bare
    # variable/literal used directly in argument position used to analyze
    # with no position at all. Walking the chain directly keeps each cell's
    # pos in hand to pass through.
    private def analyze_seq_with_pos(list : SchemeValue, env : Env, scope : AnalyzerScope) : Array(Node)
      nodes = [] of Node
      cur = list
      while cur.is_a?(Cons)
        nodes << analyze(cur.car, env, scope, cur.pos)
        cur = cur.cdr
      end
      nodes
    end

    private def analyze_app(form : Cons, env : Env, scope : AnalyzerScope) : Node
      head = form.car
      args = [] of Node
      cur = form.cdr
      while cur.is_a?(Cons)
        args << analyze(cur.car, env, scope, cur.pos)
        cur = cur.cdr
      end
      unless cur.is_a?(SchemeNil)
        # Improper argument list. A normal application evaluates the operator and
        # every proper-prefix arg BEFORE the improper tail matters, so append the
        # error as a trailing "argument" (AppNode evaluates callee then args in
        # order) to preserve that ordering (e.g. an unbound operator errors first).
        args << malformed("cannot apply: improper argument list", form)
        return AppNode.new(analyze(head, env, scope, form.pos), args, form, form.pos)
      end
      # Primitive specialization: a call whose head is a free (non-shadowed)
      # global currently bound to a known builtin, at the exact arity that
      # builtin expects, inlines the op (see PrimCallNode). Guarded at runtime
      # against redefinition.
      if head.is_a?(SchemeSym) && !scope.bound?(head.name)
        if (spec = PRIM_OPS[head.name]?) && args.size == spec[1]
          b = env.get?(head.name)
          return PrimCallNode.new(spec[0], head.name, args, b, form, form.pos) if b.is_a?(Builtin)
        elsif args.size == 1
          # car/cdr/caar/.../cddddr — the whole (scheme cxr) accessor family
          # fuses into one PrimOp::Cxr (the car/cdr chain rides in the emitted
          # operand). Keyed on the RESOLVED builtin's name, not the call's head
          # symbol, so a plain value alias fuses too: `(define first car)` binds
          # `first` to the car builtin (name "car"), and `(first x)` then fuses
          # exactly like `(car x)` — no separate alias table needed. The
          # is-it-a-cxr-named-Builtin gate is both the redefinition guard (a
          # user redefinition to a non-builtin won't fuse) and what limits this
          # to real accessors (only cxr builtins have cxr-shaped names). The
          # chain and profiler label come from the builtin's own name.
          b = env.get?(head.name)
          return PrimCallNode.new(PrimOp::Cxr, b.name, args, b, form, form.pos) if b.is_a?(Builtin) && cxr_name?(b.name)
        end
      end
      AppNode.new(analyze(head, env, scope, form.pos), args, form, form.pos)
    end

    # A car/cdr composition name: `c`, one or more `a`/`d` letters, then `r`
    # (car, cdr, caar, cadr, …, cddddr). Length isn't capped here — the
    # is-it-a-bound-Builtin gate at the call site restricts fusion to accessors
    # that actually exist.
    private def cxr_name?(name : String) : Bool
      return false unless name.size >= 3 && name.starts_with?('c') && name.ends_with?('r')
      name.each_char_with_index do |letter, i|
        next if i == 0 || i == name.size - 1
        return false unless letter == 'a' || letter == 'd'
      end
      true
    end

    # Analyze a lambda/define body with `scope` extended by the params, rest,
    # and any body-internal `define` names — so a name introduced by an
    # internal define (which could even shadow a keyword) is treated as a local
    # binding, not syntax. The runtime resolution of those names still happens
    # via VarRef against the env, where the internal define will have run first.
    private def analyze_body(params : Array(String), rparam : String?, raw_body : Array(SchemeValue), env : Env, scope : AnalyzerScope) : Array(Node)
      binders = params.dup
      binders << rparam if rparam
      # params + rest occupy fixed, always-bound slots (0..safe-1); internal
      # defines come after and are only addressable by name (their slot appears
      # at runtime once their define runs).
      safe = binders.size
      binders.concat(internal_define_names(raw_body))
      inner = scope.extend(binders, safe)
      with_child_macro_scope { raw_body.map { |sub| analyze(sub, env, inner) } }
    end

    # Run `block` with a fresh child compile-time macro scope pushed, so an
    # internal define-syntax/defmacro registered while analyzing a body is
    # visible to later forms in that body but doesn't leak to the enclosing
    # scope (mirrors the runtime lexical frame the body introduces).
    private def with_child_macro_scope(&)
      saved = @analyzing_macros
      @analyzing_macros = saved.child
      begin
        yield
      ensure
        @analyzing_macros = saved
      end
    end

    # Names bound by top-level `(define x …)` / `(define (x …) …)` /
    # `(define-values …)` forms in a body. (define-syntax / define-record-type
    # binders are not collected — they'd only matter here in the exotic case of
    # shadowing a keyword, which real code doesn't do.)
    private def internal_define_names(forms : Array(SchemeValue)) : Array(String)
      names = [] of String
      forms.each do |entry|
        next unless entry.is_a?(Cons)
        h = entry.car
        next unless h.is_a?(SchemeSym)
        d = entry.cdr
        next unless d.is_a?(Cons)
        case h.name
        when "define"
          t = d.car
          case t
          when SchemeSym then names << t.name
          when Cons
            fn = t.car
            names << fn.name if fn.is_a?(SchemeSym)
          end
        when "define-values"
          # (define-values (a b . rest) producer) also binds names in the body's
          # frame — collect them so refs are name-resolved locals, not miscached
          # as globals.
          params, rparam = parse_formals_safe(d.car)
          if params
            names.concat(params)
            names << rparam if rparam
          end
        end
      end
      names
    end

    # parse_formals, but returns {nil, nil} instead of raising on malformed
    # formals, so internal_define_names can simply skip an ill-formed binder.
    private def parse_formals_safe(spec : SchemeValue) : {Array(String)?, String?}
      parse_formals(spec)
    rescue
      {nil, nil}
    end

    private def proper_list?(v : SchemeValue) : Bool
      cur = v
      while cur.is_a?(Cons)
        cur = cur.cdr
      end
      cur.is_a?(SchemeNil)
    end
  end
end
