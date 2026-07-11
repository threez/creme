# ===========================================================================
# Interpreter: trampolined eval, apply, special forms, quasiquote
# ===========================================================================

module LISP
  class Interpreter
    DEFAULT_MAX_EVAL_DEPTH = 5_000

    getter global : Env
    getter packages : Hash(String, Env)
    property max_eval_depth : Int32
    property max_steps : Int32?
    property allowed_modules : Array(String)?
    property stdout : IO

    def initialize(
      @max_eval_depth : Int32 = DEFAULT_MAX_EVAL_DEPTH,
      @max_steps : Int32? = nil,
      @allowed_modules : Array(String)? = nil,
      @stdout : IO = STDOUT,
    )
      @global = Env.new
      @packages = {} of String => Env
      @eval_depth = 0
      @step_count = 0
      @gensym_counter = 0
      install_builtins(@global)
      load_prelude
    end

    # Safe-by-default entry point for embedding untrusted/semi-trusted guest
    # code: denies all `require` modules and captures stdout unless told
    # otherwise, so a host can't accidentally embed a wide-open interpreter
    # by forgetting to pass allowed_modules:.
    def self.sandboxed(
      allowed_modules : Array(String) = [] of String,
      max_steps : Int32? = 100_000,
      max_eval_depth : Int32 = DEFAULT_MAX_EVAL_DEPTH,
      stdout : IO = IO::Memory.new,
    ) : Interpreter
      new(max_eval_depth: max_eval_depth, max_steps: max_steps, allowed_modules: allowed_modules, stdout: stdout)
    end

    # ---- Evaluation (trampolined) --------------------------------------------

    def eval(expr : LispValue, env : Env) : LispValue
      @step_count = 0 if @eval_depth == 0
      @eval_depth += 1
      begin
        if @eval_depth > @max_eval_depth
          raise LispExecutionLimitError.new("recursion depth exceeded")
        end
        eval_core(expr, env)
      ensure
        @eval_depth -= 1
      end
    end

    private def eval_core(expr : LispValue, env : Env) : LispValue
      loop do
        if budget = @max_steps
          @step_count += 1
          if @step_count > budget
            raise LispExecutionLimitError.new("execution step limit exceeded (max_steps=#{budget})")
          end
        end
        case expr
        when LispSym
          name = expr.name
          if idx = name.index(':')
            pkg = name[0...idx]
            local = name[(idx + 1)..]
            pkg_env = @packages[pkg]? || raise LispRuntimeError.new("unbound package: #{pkg} (forgot (require #{pkg})?)")
            return pkg_env.get(local)
          end
          return env.get(name)
        when Cons
          head = expr.car
          if head.is_a?(LispSym)
            case head.name
            when "quote"
              args = LISP.list_to_a(expr.cdr)
              raise LispRuntimeError.new("quote: expects 1 argument") unless args.size == 1
              return args[0]
            when "quasiquote"
              args = LISP.list_to_a(expr.cdr)
              raise LispRuntimeError.new("quasiquote: expects 1 argument") unless args.size == 1
              return expand_qq(args[0], env, 1)
            when "unquote", "unquote-splicing"
              raise LispRuntimeError.new("#{head.name}: not valid outside quasiquote")
            when "if"
              args = LISP.list_to_a(expr.cdr)
              unless args.size == 2 || args.size == 3
                raise LispRuntimeError.new("if: expects 2 or 3 arguments")
              end
              if LISP.truthy?(eval(args[0], env))
                expr = args[1]
              else
                return NIL if args.size == 2
                expr = args[2]
              end
              next
            when "cond"
              clauses = LISP.list_to_a(expr.cdr)
              matched = false
              clauses.each do |clause|
                parts = LISP.list_to_a(clause)
                raise LispRuntimeError.new("cond: empty clause") if parts.empty?
                test = parts[0]
                is_else = test.is_a?(LispSym) && test.name == "else"
                tv = is_else ? NIL : eval(test, env)
                if is_else || LISP.truthy?(tv)
                  if parts.size == 1
                    return is_else ? NIL : tv
                  end
                  # eval body except last normally, last is tail
                  (1...parts.size - 1).each { |i| eval(parts[i], env) }
                  expr = parts[parts.size - 1]
                  matched = true
                  break
                end
              end
              next if matched
              return NIL
            when "when"
              args = LISP.list_to_a(expr.cdr)
              raise LispRuntimeError.new("when: expects a condition") if args.empty?
              if LISP.truthy?(eval(args[0], env))
                return NIL if args.size == 1
                (1...args.size - 1).each { |i| eval(args[i], env) }
                expr = args[args.size - 1]
                next
              else
                return NIL
              end
            when "unless"
              args = LISP.list_to_a(expr.cdr)
              raise LispRuntimeError.new("unless: expects a condition") if args.empty?
              unless LISP.truthy?(eval(args[0], env))
                return NIL if args.size == 1
                (1...args.size - 1).each { |i| eval(args[i], env) }
                expr = args[args.size - 1]
                next
              else
                return NIL
              end
            when "define"
              return eval_define(expr, env)
            when "defmacro"
              return eval_defmacro(expr, env)
            when "set!"
              args = LISP.list_to_a(expr.cdr)
              raise LispRuntimeError.new("set!: expects 2 arguments") unless args.size == 2
              name = args[0]
              raise LispRuntimeError.new("set!: first argument must be a symbol") unless name.is_a?(LispSym)
              return env.set!(name.name, eval(args[1], env))
            when "require"
              return eval_require(expr, env)
            when "lambda", "λ"
              return make_lambda(expr.cdr, env)
            when "let"
              new_env, body = eval_let(expr.cdr, env)
              return NIL if body.empty?
              (0...body.size - 1).each { |i| eval(body[i], new_env) }
              expr = body[body.size - 1]
              env = new_env
              next
            when "let*"
              new_env, body = eval_let_star(expr.cdr, env)
              return NIL if body.empty?
              (0...body.size - 1).each { |i| eval(body[i], new_env) }
              expr = body[body.size - 1]
              env = new_env
              next
            when "letrec"
              new_env, body = eval_letrec(expr.cdr, env)
              return NIL if body.empty?
              (0...body.size - 1).each { |i| eval(body[i], new_env) }
              expr = body[body.size - 1]
              env = new_env
              next
            when "begin"
              body = LISP.list_to_a(expr.cdr)
              return NIL if body.empty?
              (0...body.size - 1).each { |i| eval(body[i], env) }
              expr = body[body.size - 1]
              next
            when "and"
              operands = LISP.list_to_a(expr.cdr)
              return TRUE if operands.empty?
              (0...operands.size - 1).each do |i|
                v = eval(operands[i], env)
                return v unless LISP.truthy?(v)
              end
              expr = operands[operands.size - 1]
              next
            when "or"
              operands = LISP.list_to_a(expr.cdr)
              return FALSE if operands.empty?
              (0...operands.size - 1).each do |i|
                v = eval(operands[i], env)
                return v if LISP.truthy?(v)
              end
              expr = operands[operands.size - 1]
              next
            else
              # fall through to application
            end
          end

          # Application: evaluate head and args
          callee = eval(head, env)

          if callee.is_a?(Macro)
            arg_forms = [] of LispValue
            c = expr.cdr
            while c.is_a?(Cons)
              arg_forms << c.car
              c = c.cdr
            end
            raise LispRuntimeError.new("cannot apply: improper argument list") unless c.is_a?(LispNil)

            call_env = Env.new(callee.env)
            bind_params(callee, arg_forms, call_env)
            expansion : LispValue = NIL
            callee.body.each { |form| expansion = eval(form, call_env) }

            # `env` is intentionally left unchanged: the expansion must evaluate at
            # the call site, not inside the macro's own parameter-binding frame.
            # Note: a macro whose expansion (directly, or via typo) invokes itself
            # loops forever without ever raising "recursion depth exceeded" — the
            # same @eval_depth-flat behavior as an existing infinite tail call like
            # `(define (f) (f))`. This is accepted as consistent with that existing
            # behavior, not treated as a new failure mode to guard against.
            expr = expansion
            next
          end

          args = [] of LispValue
          cur = expr.cdr
          while cur.is_a?(Cons)
            args << eval(cur.car, env)
            cur = cur.cdr
          end
          unless cur.is_a?(LispNil)
            raise LispRuntimeError.new("cannot apply: improper argument list")
          end

          # Tail call for Lambda: reuse loop
          if callee.is_a?(Lambda)
            call_env = Env.new(callee.env)
            bind_params(callee, args, call_env)
            body = callee.body
            return NIL if body.empty?
            (0...body.size - 1).each { |i| eval(body[i], call_env) }
            expr = body[body.size - 1]
            env = call_env
            next
          else
            return apply(callee, args)
          end
        else
          return expr
        end
      end
    end

    # ---- Application ----------------------------------------------------------

    def apply(callee : LispValue, args : Array(LispValue)) : LispValue
      case callee
      when Builtin
        check_arity(callee, args)
        callee.fn.call(args)
      when Lambda
        call_env = Env.new(callee.env)
        bind_params(callee, args, call_env)
        result : LispValue = NIL
        callee.body.each { |form| result = eval(form, call_env) }
        result
      when Macro
        raise LispRuntimeError.new("macro cannot be applied as a procedure: #{callee.name}")
      else
        raise LispRuntimeError.new("not applicable: #{callee.write_string}")
      end
    end

    private def check_arity(b : Builtin, args : Array(LispValue)) : Nil
      n = args.size
      if n < b.min_arity
        raise LispRuntimeError.new("#{b.name}: expected at least #{b.min_arity} argument(s), got #{n}")
      end
      if b.max_arity >= 0 && n > b.max_arity
        raise LispRuntimeError.new("#{b.name}: expected at most #{b.max_arity} argument(s), got #{n}")
      end
    end

    private def bind_params(lam : Lambda | Macro, args : Array(LispValue), call_env : Env) : Nil
      params = lam.params
      rest = lam.rest
      if rest
        if args.size < params.size
          raise LispRuntimeError.new("#{lam.name}: expected at least #{params.size} argument(s), got #{args.size}")
        end
      else
        if args.size != params.size
          raise LispRuntimeError.new("#{lam.name}: expected #{params.size} argument(s), got #{args.size}")
        end
      end
      params.each_with_index do |p, i|
        call_env.define(p, args[i])
      end
      if r = rest
        extra = args[params.size..-1]
        call_env.define(r, LISP.a_to_list(extra))
      end
    end

    # ---- Special-form helpers -------------------------------------------------

    private def eval_define(expr : Cons, env : Env) : LispValue
      rest = expr.cdr
      raise LispRuntimeError.new("define: malformed") unless rest.is_a?(Cons)
      target = rest.car
      case target
      when LispSym
        body = LISP.list_to_a(rest.cdr)
        if body.empty?
          val : LispValue = NIL
        else
          raise LispRuntimeError.new("define: expects 1 value expression") unless body.size == 1
          val = eval(body[0], env)
        end
        if val.is_a?(Lambda) && val.name == "lambda"
          val.name = target.name
        end
        env.define(target.name, val)
        target
      when Cons
        # (define (f a b . rest) body...)
        fname = target.car
        raise LispRuntimeError.new("define: function name must be a symbol") unless fname.is_a?(LispSym)
        formals = target.cdr
        body = LISP.list_to_a(rest.cdr)
        raise LispRuntimeError.new("define: function body is empty") if body.empty?
        params, rparam = parse_formals(formals)
        lam = Lambda.new(params, rparam, body, env, fname.name)
        env.define(fname.name, lam)
        fname
      else
        raise LispRuntimeError.new("define: bad target #{target.write_string}")
      end
    end

    private def eval_defmacro(expr : Cons, env : Env) : LispValue
      rest = expr.cdr
      raise LispRuntimeError.new("defmacro: malformed") unless rest.is_a?(Cons)
      name = rest.car
      raise LispRuntimeError.new("defmacro: macro name must be a symbol") unless name.is_a?(LispSym)
      formals_rest = rest.cdr
      raise LispRuntimeError.new("defmacro: malformed") unless formals_rest.is_a?(Cons)
      formals = formals_rest.car
      body = LISP.list_to_a(formals_rest.cdr)
      raise LispRuntimeError.new("defmacro: macro body is empty") if body.empty?
      params, rparam = parse_formals(formals)
      mac = Macro.new(params, rparam, body, env, name.name)
      env.define(name.name, mac)
      name
    end

    private def make_lambda(rest : LispValue, env : Env) : Lambda
      raise LispRuntimeError.new("lambda: malformed") unless rest.is_a?(Cons)
      formals = rest.car
      body = LISP.list_to_a(rest.cdr)
      raise LispRuntimeError.new("lambda: empty body") if body.empty?
      params, rparam = parse_formals(formals)
      Lambda.new(params, rparam, body, env, "lambda")
    end

    # Returns {params, rest}
    def parse_formals(spec : LispValue) : {Array(String), String?}
      params = [] of String
      rest : String? = nil
      case spec
      when LispSym
        # (lambda args ...) full variadic
        rest = spec.name
      when LispNil
        # no params
      when Cons
        cur : LispValue = spec
        while cur.is_a?(Cons)
          head = cur.car
          raise LispRuntimeError.new("bad formal parameter: #{head.write_string}") unless head.is_a?(LispSym)
          params << head.name
          cur = cur.cdr
        end
        unless cur.is_a?(LispNil)
          raise LispRuntimeError.new("bad rest parameter: #{cur.write_string}") unless cur.is_a?(LispSym)
          rest = cur.name
        end
      else
        raise LispRuntimeError.new("bad formals: #{spec.write_string}")
      end
      {params, rest}
    end

    # returns {new_env, body}
    private def eval_let(rest : LispValue, env : Env) : {Env, Array(LispValue)}
      raise LispRuntimeError.new("let: malformed") unless rest.is_a?(Cons)
      bindings = LISP.list_to_a(rest.car)
      body = LISP.list_to_a(rest.cdr)
      new_env = Env.new(env)
      # evaluate all inits in OUTER env
      names = [] of String
      vals = [] of LispValue
      bindings.each do |b|
        parts = LISP.list_to_a(b)
        raise LispRuntimeError.new("let: bad binding") unless parts.size == 2
        name = parts[0]
        raise LispRuntimeError.new("let: binding name must be symbol") unless name.is_a?(LispSym)
        names << name.name
        vals << eval(parts[1], env)
      end
      names.each_with_index { |n, i| new_env.define(n, vals[i]) }
      {new_env, body}
    end

    private def eval_let_star(rest : LispValue, env : Env) : {Env, Array(LispValue)}
      raise LispRuntimeError.new("let*: malformed") unless rest.is_a?(Cons)
      bindings = LISP.list_to_a(rest.car)
      body = LISP.list_to_a(rest.cdr)
      new_env = Env.new(env)
      bindings.each do |b|
        parts = LISP.list_to_a(b)
        raise LispRuntimeError.new("let*: bad binding") unless parts.size == 2
        name = parts[0]
        raise LispRuntimeError.new("let*: binding name must be symbol") unless name.is_a?(LispSym)
        new_env.define(name.name, eval(parts[1], new_env))
      end
      {new_env, body}
    end

    private def eval_letrec(rest : LispValue, env : Env) : {Env, Array(LispValue)}
      raise LispRuntimeError.new("letrec: malformed") unless rest.is_a?(Cons)
      bindings = LISP.list_to_a(rest.car)
      body = LISP.list_to_a(rest.cdr)
      new_env = Env.new(env)
      parsed = [] of {String, LispValue}
      bindings.each do |b|
        parts = LISP.list_to_a(b)
        raise LispRuntimeError.new("letrec: bad binding") unless parts.size == 2
        name = parts[0]
        raise LispRuntimeError.new("letrec: binding name must be symbol") unless name.is_a?(LispSym)
        new_env.define(name.name, NIL)
        parsed << {name.name, parts[1]}
      end
      parsed.each do |name, init|
        new_env.define(name, eval(init, new_env))
      end
      {new_env, body}
    end

    # ---- Quasiquote -----------------------------------------------------------

    def expand_qq(tmpl : LispValue, env : Env, depth : Int32) : LispValue
      unless tmpl.is_a?(Cons)
        return tmpl
      end

      head = tmpl.car
      if head.is_a?(LispSym)
        case head.name
        when "unquote"
          inner = LISP.list_to_a(tmpl.cdr)
          raise LispRuntimeError.new("unquote: expects 1 argument") unless inner.size == 1
          if depth == 1
            return eval(inner[0], env)
          else
            return LISP.a_to_list([LispSym.of("unquote"), expand_qq(inner[0], env, depth - 1)] of LispValue)
          end
        when "quasiquote"
          inner = LISP.list_to_a(tmpl.cdr)
          raise LispRuntimeError.new("quasiquote: expects 1 argument") unless inner.size == 1
          return LISP.a_to_list([LispSym.of("quasiquote"), expand_qq(inner[0], env, depth + 1)] of LispValue)
        else
          # fall through
        end
      end

      # rebuild list honoring splicing in car position
      result_items = [] of LispValue
      cur : LispValue = tmpl
      tail : LispValue = NIL
      while cur.is_a?(Cons)
        elem = cur.car
        if elem.is_a?(Cons) && (eh = elem.car).is_a?(LispSym) && eh.name == "unquote-splicing" && depth == 1
          spliced_form = LISP.list_to_a(elem.cdr)
          raise LispRuntimeError.new("unquote-splicing: expects 1 argument") unless spliced_form.size == 1
          spliced = eval(spliced_form[0], env)
          LISP.list_to_a(spliced).each { |x| result_items << x }
          cur = cur.cdr
        elsif elem.is_a?(Cons) && (eh2 = elem.car).is_a?(LispSym) && eh2.name == "unquote-splicing"
          # deeper depth: rebuild
          inner = LISP.list_to_a(elem.cdr)
          result_items << LISP.a_to_list([LispSym.of("unquote-splicing"), expand_qq(inner[0], env, depth - 1)] of LispValue)
          cur = cur.cdr
        else
          # check if cdr is an unquote form (dotted unquote): `(a . ,b)
          cdr = cur.cdr
          if cdr.is_a?(Cons) && (ch = cdr.car).is_a?(LispSym) && ch.name == "unquote" && depth == 1
            result_items << expand_qq(elem, env, depth)
            uq = LISP.list_to_a(cdr.cdr)
            raise LispRuntimeError.new("unquote: expects 1 argument") unless uq.size == 1
            tail = eval(uq[0], env)
            cur = NIL
            break
          end
          result_items << expand_qq(elem, env, depth)
          cur = cur.cdr
        end
      end
      unless cur.is_a?(LispNil)
        tail = expand_qq(cur, env, depth)
      end
      LISP.a_to_list(result_items, tail)
    end
  end
end
