# ===========================================================================
# Interpreter: trampolined eval, apply, special forms, quasiquote
# ===========================================================================

module Scheme
  class Interpreter
    DEFAULT_MAX_EVAL_DEPTH = 5_000

    getter global : Env
    # Where builtins/prelude/bytevectors/exceptions/special-forms physically
    # live — the source every (scheme base)/(scheme write)/sub-library/
    # (list ...) installer copies its bindings from via `@base_env.get(name)`.
    # Distinct from @global (the top-level program's own root Env) so that
    # auto_import_base: false can leave @global empty until the program
    # explicitly (import (scheme base)), without needing a second copy of
    # every builtin.
    getter base_env : Env
    # A fixed reference point captured at construction, for (scheme time)'s
    # current-jiffy — an arbitrary monotonic counter, per R7RS, not tied to
    # any particular epoch.
    getter start_instant : Time::Instant
    property max_eval_depth : Int32
    property max_steps : Int32?

    # Restricts which libraries (import ...) may resolve, by space-joined
    # name (e.g. "creme sql" for (creme sql), "scheme base" for (scheme
    # base)) — nil (the default) means unrestricted. Renamed from the
    # require-era allowed_modules (a bare module-name allowlist) now that
    # import/library names are the unit of access control.
    property allowed_libraries : Array(String)?

    # Directories searched (in order) for a "#{a}/#{b}/#{c}.sld" file when
    # (import (a b c)) names something other than a Crystal-native library —
    # e.g. modules/creme/sxql.sld. Empty by default: a host embedding this
    # library opts in explicitly (see main.cr/spec_helper.cr), rather than
    # the interpreter silently depending on a filesystem layout. This list
    # IS the access-control boundary for file-based libraries (there's no
    # raw-path import form the way require had (require "some/path.scm"),
    # so there's no separate library_load_paths-style path-escape gate to
    # rename from require-era module_load_paths — only files discoverable
    # under these directories, via a name whose segments are validated
    # against path traversal in SchemeLibrary.parse_library_name, are ever
    # reachable).
    property library_search_path : Array(String)

    # Real R7RS parameter objects backing current-output-port/
    # current-input-port/current-error-port, so `(parameterize
    # ((current-output-port p)) ...)` genuinely redirects display/write/
    # newline's no-port-given default target — the portable mechanism
    # (scheme eval)'s eval + this needs to replace eval-string's old
    # Crystal-side @stdout swap (see interpreter/builtins.cr's emit).
    # Each parameter's default (unparameterized) value is a SchemePort
    # wrapping @stdout/@stdin/@stderr directly — the stdout=/stdin=/
    # stderr= setters below resync that same port's `.io` whenever set,
    # so they keep working exactly as before when no script has
    # parameterized the port itself.
    getter current_output_port : SchemeParameter
    getter current_input_port : SchemeParameter
    getter current_error_port : SchemeParameter

    def stdout : IO
      @stdout
    end

    def stdout=(io : IO) : IO
      @stdout = io
      default_output_port.io = io
      io
    end

    def stdin : IO
      @stdin
    end

    def stdin=(io : IO) : IO
      @stdin = io
      default_input_port.io = io
      io
    end

    def stderr : IO
      @stderr
    end

    def stderr=(io : IO) : IO
      @stderr = io
      default_error_port.io = io
      io
    end

    # The SchemePort each current_*_port parameter is constructed with at
    # startup (before any parameterize) — stdout=/stdin=/stderr= resync
    # THIS object's `.io` in place, rather than replacing the parameter's
    # value outright, so a currently-active `parameterize` isn't clobbered
    # by an unrelated `interp.stdout = io` call racing with it.
    private def default_output_port : SchemePort
      current_output_port.value.as(SchemePort)
    end

    private def default_input_port : SchemePort
      current_input_port.value.as(SchemePort)
    end

    private def default_error_port : SchemePort
      current_error_port.value.as(SchemePort)
    end

    def initialize(
      @max_eval_depth : Int32 = DEFAULT_MAX_EVAL_DEPTH,
      @max_steps : Int32? = nil,
      @allowed_libraries : Array(String)? = nil,
      @library_search_path : Array(String) = [] of String,
      @stdout : IO = STDOUT,
      @stdin : IO = STDIN,
      @stderr : IO = STDERR,
      auto_import_base : Bool = true,
    )
      @base_env = Env.new
      @global = Env.new
      @load_dirs = [] of String
      @libraries = {} of Array(String) => SchemeLibrary
      @libraries_loading = Set(Array(String)).new
      @eval_depth = 0
      @step_count = 0
      @gensym_counter = 0
      @cc_tag_counter = 0_i64
      @live_continuation_tags = Set(Int64).new
      @call_stack = [] of Frame
      @start_instant = Time.instant
      @exception_handlers = [] of SchemeValue
      @current_output_port = SchemeParameter.new(SchemePort.new(@stdout, false, true))
      @current_input_port = SchemeParameter.new(SchemePort.new(@stdin, true, false))
      @current_error_port = SchemeParameter.new(SchemePort.new(@stderr, false, true))
      install_builtins(@base_env)
      install_bytevectors(@base_env)
      install_exceptions(@base_env)
      install_special_forms(@base_env)
      load_prelude
      install_base_and_write_libraries
      install_sub_libraries
      install_creme_libraries
      install_complex_library
      # Special forms (if/define/import/...) must always be visible so a
      # program can even parse far enough to reach its own `import`
      # statement — these are syntactic keywords, not (scheme base)
      # content, so they're copied into @global unconditionally regardless
      # of auto_import_base.
      SPECIAL_FORM_NAMES.each { |name| @global.define(name, @base_env.get(name)) }
      if auto_import_base
        AUTO_IMPORTED_LIBRARIES.each do |name|
          library = @libraries[name]
          SchemeLibrary.import_bindings(@global, library.exports.map { |external, internal| {external, library, internal} })
        end
      end
    end

    # Every keyword eval_core's case statement (below) recognizes by literal
    # symbol text — bound in @global as a SchemeSpecialForm marker so each
    # one participates in ordinary lexical scoping/import/export/rename like
    # any other identifier (see SchemeSpecialForm's doc comment in
    # values.cr). Keep in sync with the `case head.name` arms in eval_core.
    SPECIAL_FORM_NAMES = %w[
      quote quasiquote unquote unquote-splicing
      if cond case when unless cond-expand
      define defmacro define-record-type define-syntax define-library import
      define-values let-values let*-values let-syntax letrec-syntax
      set! lambda λ case-lambda delay parameterize guard
      let let* letrec letrec* do begin and or
      include include-ci
    ]

    private def install_special_forms(env : Env) : Nil
      SPECIAL_FORM_NAMES.each { |name| env.define(name, SchemeSpecialForm.new(name)) }
    end

    # Safe-by-default entry point for embedding untrusted/semi-trusted guest
    # code: denies all library imports and captures stdout/stdin unless told
    # otherwise, so a host can't accidentally embed a wide-open interpreter
    # by forgetting to pass allowed_libraries: — and guest code reading
    # (read-line) can't block on the host's real terminal input.
    # auto_import_base defaults to false here (unlike Interpreter.new) so
    # "denies all library imports" is actually true: auto-import binds
    # (scheme base)/(scheme write)/(creme extra) into @global at
    # construction, bypassing allowed_libraries entirely (see
    # AUTO_IMPORTED_LIBRARIES in interpreter/base_library.cr) — leaving it
    # true here would silently hand guest code a working base environment
    # no matter what allowed_libraries said.
    def self.sandboxed(
      allowed_libraries : Array(String) = [] of String,
      max_steps : Int32? = 100_000,
      max_eval_depth : Int32 = DEFAULT_MAX_EVAL_DEPTH,
      stdout : IO = IO::Memory.new,
      stdin : IO = IO::Memory.new,
      stderr : IO = IO::Memory.new,
      auto_import_base : Bool = false,
    ) : Interpreter
      new(max_eval_depth: max_eval_depth, max_steps: max_steps, allowed_libraries: allowed_libraries, stdout: stdout, stdin: stdin, stderr: stderr, auto_import_base: auto_import_base)
    end

    # ---- Evaluation (trampolined) --------------------------------------------

    def eval(expr : SchemeValue, env : Env) : SchemeValue
      top_level = @eval_depth == 0
      @step_count = 0 if top_level
      @eval_depth += 1
      Interpreter.push_current(self) if top_level
      pos = expr.is_a?(Cons) ? expr.pos : nil
      @call_stack << Frame.new("", pos)
      begin
        if @eval_depth > @max_eval_depth
          raise SchemeExecutionLimitError.new("recursion depth exceeded")
        end
        eval_core(expr, env)
      ensure
        @call_stack.pop
        @eval_depth -= 1
        Interpreter.pop_current if @eval_depth == 0
      end
    end

    # ---- Backtrace support ----------------------------------------------------

    @@current_stack = [] of Interpreter

    # The interpreter instance whose eval() call chain is currently active on
    # this fiber, if any — used so a SchemeError can eagerly capture a
    # backtrace at construction time without every raise site needing a
    # reference to the interpreter.
    def self.current : Interpreter?
      @@current_stack.last?
    end

    def self.push_current(interp : Interpreter) : Nil
      @@current_stack << interp
    end

    def self.pop_current : Nil
      @@current_stack.pop?
    end

    def call_stack_snapshot : Array(Frame)
      @call_stack.dup
    end

    def current_pos : SourcePos?
      @call_stack.last?.try(&.pos)
    end

    # Returns Scheme.list_to_a(form.cdr), transparently cached on `form` (a
    # Cons) so that repeatedly-evaluated special-form nodes (an `if` inside
    # a recursive function's body, e.g.) parse their argument list once
    # instead of re-walking and re-allocating on every visit. See
    # Cons#cached_args in values.cr for why this is safe to cache.
    private def cached_form_args(form : Cons) : Array(SchemeValue)
      form.cached_args ||= Scheme.list_to_a(form.cdr)
    end

    # ameba:disable Metrics/CyclomaticComplexity
    private def eval_core(expr : SchemeValue, env : Env) : SchemeValue
      loop do
        if budget = @max_steps
          @step_count += 1
          if @step_count > budget
            raise SchemeExecutionLimitError.new("execution step limit exceeded (max_steps=#{budget})")
          end
        end
        case expr
        when SchemeSym
          return env.get(expr.name)
        when Cons
          head = expr.car
          head_binding = head.is_a?(SchemeSym) ? env.get?(head.name) : nil
          if head.is_a?(SchemeSym) && (head_binding.nil? || head_binding.is_a?(SchemeSpecialForm))
            case head.name
            when "quote"
              args = Scheme.list_to_a(expr.cdr)
              raise SchemeRuntimeError.new("quote: expects 1 argument") unless args.size == 1
              return args[0]
            when "quasiquote"
              args = Scheme.list_to_a(expr.cdr)
              raise SchemeRuntimeError.new("quasiquote: expects 1 argument") unless args.size == 1
              return expand_qq(args[0], env, 1)
            when "unquote", "unquote-splicing"
              raise SchemeRuntimeError.new("#{head.name}: not valid outside quasiquote")
            when "if"
              args = cached_form_args(expr)
              unless args.size == 2 || args.size == 3
                raise SchemeRuntimeError.new("if: expects 2 or 3 arguments")
              end
              if Scheme.truthy?(eval(args[0], env))
                expr = args[1]
              else
                return NIL if args.size == 2
                expr = args[2]
              end
              next
            when "cond"
              tail_expr, is_tail = eval_cond(expr.cdr, env)
              return tail_expr unless is_tail
              expr = tail_expr
              next
            when "case"
              case_pos = expr.pos
              cargs = Scheme.list_to_a(expr.cdr)
              raise SchemeRuntimeError.new("case: expects a key expression") if cargs.empty?
              key = eval(cargs[0], env)
              clauses = cargs[1..]
              matched = false
              clauses.each do |clause|
                parts = Scheme.list_to_a(clause)
                raise SchemeRuntimeError.new("case: empty clause") if parts.empty?
                test = parts[0]
                is_else = test.is_a?(SchemeSym) && test.name == "else"
                unless is_else
                  datums = Scheme.list_to_a(test)
                  next unless datums.any? { |datum| Scheme.scheme_eqv?(key, datum) }
                end
                body = parts[1..]
                if body.size == 2 && (arrow = body[0]).is_a?(SchemeSym) && arrow.name == "=>"
                  receiver = eval(body[1], env)
                  return apply(receiver, [key], case_pos)
                end
                if body.empty?
                  return NIL
                end
                (0...body.size - 1).each { |i| eval(body[i], env) }
                expr = body[body.size - 1]
                matched = true
                break
              end
              next if matched
              return NIL
            when "when"
              args = cached_form_args(expr)
              raise SchemeRuntimeError.new("when: expects a condition") if args.empty?
              if Scheme.truthy?(eval(args[0], env))
                return NIL if args.size == 1
                (1...args.size - 1).each { |i| eval(args[i], env) }
                expr = args[args.size - 1]
                next
              else
                return NIL
              end
            when "unless"
              args = cached_form_args(expr)
              raise SchemeRuntimeError.new("unless: expects a condition") if args.empty?
              if Scheme.truthy?(eval(args[0], env))
                return NIL
              else
                return NIL if args.size == 1
                (1...args.size - 1).each { |i| eval(args[i], env) }
                expr = args[args.size - 1]
                next
              end
            when "define"
              return eval_define(expr, env)
            when "defmacro"
              return eval_defmacro(expr, env)
            when "define-record-type"
              return eval_define_record_type(expr, env)
            when "define-syntax"
              return eval_define_syntax(expr, env)
            when "define-library"
              return eval_define_library(expr, env)
            when "import"
              return eval_import(expr, env)
            when "set!"
              args = Scheme.list_to_a(expr.cdr)
              raise SchemeRuntimeError.new("set!: expects 2 arguments") unless args.size == 2
              name = args[0]
              raise SchemeRuntimeError.new("set!: first argument must be a symbol") unless name.is_a?(SchemeSym)
              return env.set!(name.name, eval(args[1], env))
            when "lambda", "λ"
              return make_lambda(expr.cdr, env)
            when "case-lambda"
              return make_case_lambda(expr.cdr, env)
            when "define-values"
              return eval_define_values(expr.cdr, env)
            when "let-values"
              new_env, body = eval_let_values(expr.cdr, env, sequential: false)
              return NIL if body.empty?
              (0...body.size - 1).each { |i| eval(body[i], new_env) }
              expr = body[body.size - 1]
              env = new_env
              next
            when "let*-values"
              new_env, body = eval_let_values(expr.cdr, env, sequential: true)
              return NIL if body.empty?
              (0...body.size - 1).each { |i| eval(body[i], new_env) }
              expr = body[body.size - 1]
              env = new_env
              next
            when "let-syntax", "letrec-syntax"
              new_env, body = eval_let_syntax(expr.cdr, env)
              return NIL if body.empty?
              (0...body.size - 1).each { |i| eval(body[i], new_env) }
              expr = body[body.size - 1]
              env = new_env
              next
            when "cond-expand"
              return eval_cond_expand(expr.cdr, env)
            when "delay", "delay-force"
              dargs = Scheme.list_to_a(expr.cdr)
              raise SchemeRuntimeError.new("#{head.name}: expects 1 argument") unless dargs.size == 1
              return SchemePromise.new(dargs[0], env)
            when "parameterize"
              return eval_parameterize(expr.cdr, env)
            when "guard"
              return eval_guard(expr.cdr, env)
            when "let"
              let_rest = expr.cdr
              if let_rest.is_a?(Cons) && (loop_name = let_rest.car).is_a?(SchemeSym)
                call_env, body = eval_named_let(loop_name, let_rest.cdr, env)
                return NIL if body.empty?
                let_pos = expr.pos
                (0...body.size - 1).each { |i| eval(body[i], call_env) }
                @call_stack[-1] = Frame.new(loop_name.name, let_pos)
                expr = body[body.size - 1]
                env = call_env
                next
              end
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
            when "letrec", "letrec*"
              new_env, body = head.name == "letrec" ? eval_letrec(expr.cdr, env) : eval_letrec_star(expr.cdr, env)
              return NIL if body.empty?
              (0...body.size - 1).each { |i| eval(body[i], new_env) }
              expr = body[body.size - 1]
              env = new_env
              next
            when "do"
              iter_env, result_exprs = eval_do(expr.cdr, env)
              return NIL if result_exprs.empty?
              (0...result_exprs.size - 1).each { |i| eval(result_exprs[i], iter_env) }
              expr = result_exprs[result_exprs.size - 1]
              env = iter_env
              next
            when "begin"
              body = Scheme.list_to_a(expr.cdr)
              return NIL if body.empty?
              (0...body.size - 1).each { |i| eval(body[i], env) }
              expr = body[body.size - 1]
              next
            when "include", "include-ci"
              body = eval_include(Scheme.list_to_a(expr.cdr), head.name == "include-ci")
              return NIL if body.empty?
              (0...body.size - 1).each { |i| eval(body[i], env) }
              expr = body[body.size - 1]
              next
            when "and"
              operands = cached_form_args(expr)
              return TRUE if operands.empty?
              (0...operands.size - 1).each do |i|
                v = eval(operands[i], env)
                return v unless Scheme.truthy?(v)
              end
              expr = operands[operands.size - 1]
              next
            when "or"
              operands = cached_form_args(expr)
              return FALSE if operands.empty?
              (0...operands.size - 1).each do |i|
                v = eval(operands[i], env)
                return v if Scheme.truthy?(v)
              end
              expr = operands[operands.size - 1]
              next
            else
              # fall through to application
            end
          end

          # Application: evaluate head and args. If head was a SchemeSym
          # already resolved above (head_binding), reuse that lookup instead
          # of resolving it a second time — e.g. an identifier that shadowed
          # a special form (a local define, define-syntax, or a renamed
          # import) falls straight through to here with head_binding already
          # holding its value.
          callee = head.is_a?(SchemeSym) ? (head_binding || env.get(head.name)) : eval(head, env)

          if callee.is_a?(Macro)
            arg_forms = [] of SchemeValue
            c = expr.cdr
            while c.is_a?(Cons)
              arg_forms << c.car
              c = c.cdr
            end
            raise SchemeRuntimeError.new("cannot apply: improper argument list") unless c.is_a?(SchemeNil)

            call_env = Env.new(callee.env)
            bind_params(callee, arg_forms, call_env)
            expansion : SchemeValue = NIL
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

          if callee.is_a?(SchemeSyntaxRules)
            expr = expand_syntax_rules(callee, expr)
            next
          end

          args = [] of SchemeValue
          cur = expr.cdr
          while cur.is_a?(Cons)
            args << eval(cur.car, env)
            cur = cur.cdr
          end
          unless cur.is_a?(SchemeNil)
            raise SchemeRuntimeError.new("cannot apply: improper argument list")
          end

          # A case-lambda in tail position resolves to one of its clauses
          # (an ordinary Lambda) and flows through the same tail-call path
          # below as a directly-called Lambda would.
          callee = select_case_lambda_clause(callee, args.size) if callee.is_a?(CaseLambda)

          # Tail call for Lambda: reuse loop
          if callee.is_a?(Lambda)
            call_env = Env.new(callee.env)
            bind_params(callee, args, call_env)
            body = callee.body
            # Replace (not push) the current frame: this is a genuine tail
            # call, so it must not grow the backtrace any more than it grows
            # the Crystal stack.
            @call_stack[-1] = Frame.new(callee.name, expr.pos)
            return NIL if body.empty?
            (0...body.size - 1).each { |i| eval(body[i], call_env) }
            expr = body[body.size - 1]
            env = call_env
            next
          else
            return apply(callee, args, expr.pos)
          end
        else
          return expr
        end
      end
    end

    # ---- Application ----------------------------------------------------------

    def apply(callee : SchemeValue, args : Array(SchemeValue), pos : SourcePos? = nil) : SchemeValue
      case callee
      when Builtin
        check_arity(callee, args)
        @call_stack << Frame.new(callee.name, pos)
        begin
          callee.fn.call(args)
        ensure
          @call_stack.pop
        end
      when Lambda
        call_env = Env.new(callee.env)
        bind_params(callee, args, call_env)
        @call_stack << Frame.new(callee.name, pos)
        begin
          result : SchemeValue = NIL
          callee.body.each { |form| result = eval(form, call_env) }
          result
        ensure
          @call_stack.pop
        end
      when CaseLambda
        apply(select_case_lambda_clause(callee, args.size), args, pos)
      when Macro
        raise SchemeRuntimeError.new("macro cannot be applied as a procedure: #{callee.name}")
      when SchemeParameter
        raise SchemeRuntimeError.new("parameter: expected 0 arguments, got #{args.size}") unless args.empty?
        callee.value
      when SchemeContinuation
        raise SchemeRuntimeError.new("continuation: expected 1 argument, got #{args.size}") unless args.size == 1
        unless @live_continuation_tags.includes?(callee.tag)
          raise SchemeRuntimeError.new("continuation invoked outside its dynamic extent")
        end
        raise ContinuationInvoked.new(callee.tag, args[0])
      else
        raise SchemeRuntimeError.new("not applicable: #{callee.write_string}")
      end
    end

    private def check_arity(b : Builtin, args : Array(SchemeValue)) : Nil
      n = args.size
      if n < b.min_arity
        raise SchemeRuntimeError.new("#{b.name}: expected at least #{b.min_arity} argument(s), got #{n}")
      end
      if b.max_arity >= 0 && n > b.max_arity
        raise SchemeRuntimeError.new("#{b.name}: expected at most #{b.max_arity} argument(s), got #{n}")
      end
    end

    private def bind_params(lam : Lambda | Macro, args : Array(SchemeValue), call_env : Env) : Nil
      params = lam.params
      rest = lam.rest
      if rest
        if args.size < params.size
          raise SchemeRuntimeError.new("#{lam.name}: expected at least #{params.size} argument(s), got #{args.size}")
        end
      else
        if args.size != params.size
          raise SchemeRuntimeError.new("#{lam.name}: expected #{params.size} argument(s), got #{args.size}")
        end
      end
      params.each_with_index do |param, i|
        call_env.define(param, args[i])
      end
      if r = rest
        extra = args[params.size..-1]
        call_env.define(r, Scheme.a_to_list(extra))
      end
    end

    # ---- Special-form helpers -------------------------------------------------

    private def eval_define(expr : Cons, env : Env) : SchemeValue
      rest = expr.cdr
      raise SchemeRuntimeError.new("define: malformed") unless rest.is_a?(Cons)
      target = rest.car
      case target
      when SchemeSym
        body = Scheme.list_to_a(rest.cdr)
        if body.empty?
          val : SchemeValue = NIL
        else
          raise SchemeRuntimeError.new("define: expects 1 value expression") unless body.size == 1
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
        raise SchemeRuntimeError.new("define: function name must be a symbol") unless fname.is_a?(SchemeSym)
        formals = target.cdr
        body = Scheme.list_to_a(rest.cdr)
        raise SchemeRuntimeError.new("define: function body is empty") if body.empty?
        params, rparam = parse_formals(formals)
        lam = Lambda.new(params, rparam, body, env, fname.name)
        env.define(fname.name, lam)
        fname
      else
        raise SchemeRuntimeError.new("define: bad target #{target.write_string}")
      end
    end

    private def eval_defmacro(expr : Cons, env : Env) : SchemeValue
      rest = expr.cdr
      raise SchemeRuntimeError.new("defmacro: malformed") unless rest.is_a?(Cons)
      name = rest.car
      raise SchemeRuntimeError.new("defmacro: macro name must be a symbol") unless name.is_a?(SchemeSym)
      formals_rest = rest.cdr
      raise SchemeRuntimeError.new("defmacro: malformed") unless formals_rest.is_a?(Cons)
      formals = formals_rest.car
      body = Scheme.list_to_a(formals_rest.cdr)
      raise SchemeRuntimeError.new("defmacro: macro body is empty") if body.empty?
      params, rparam = parse_formals(formals)
      mac = Macro.new(params, rparam, body, env, name.name)
      env.define(name.name, mac)
      name
    end

    private def make_lambda(rest : SchemeValue, env : Env) : Lambda
      raise SchemeRuntimeError.new("lambda: malformed") unless rest.is_a?(Cons)
      formals = rest.car
      body = Scheme.list_to_a(rest.cdr)
      raise SchemeRuntimeError.new("lambda: empty body") if body.empty?
      params, rparam = parse_formals(formals)
      Lambda.new(params, rparam, body, env, "lambda")
    end

    private def make_case_lambda(rest : SchemeValue, env : Env) : CaseLambda
      clauses = Scheme.list_to_a(rest).map do |clause|
        raise SchemeRuntimeError.new("case-lambda: malformed clause") unless clause.is_a?(Cons)
        make_lambda(clause, env)
      end
      raise SchemeRuntimeError.new("case-lambda: expects at least 1 clause") if clauses.empty?
      CaseLambda.new(clauses, "case-lambda")
    end

    # Picks the first clause whose arity accepts `argc` — an exact match for
    # a fixed-arity clause (no rest param), or argc >= params.size for a
    # clause with one. Shared by apply's non-tail CaseLambda arm and
    # eval_core's tail-call arm, so both dispatch identically.
    private def select_case_lambda_clause(callee : CaseLambda, argc : Int32) : Lambda
      clause = callee.clauses.find do |candidate|
        candidate.rest ? argc >= candidate.params.size : argc == candidate.params.size
      end
      clause || raise SchemeRuntimeError.new("#{callee.name}: no matching clause for #{argc} argument(s)")
    end

    # Returns {params, rest}
    def parse_formals(spec : SchemeValue) : {Array(String), String?}
      params = [] of String
      rest : String? = nil
      case spec
      when SchemeSym
        # (lambda args ...) full variadic
        rest = spec.name
      when SchemeNil
        # no params
      when Cons
        cur : SchemeValue = spec
        while cur.is_a?(Cons)
          head = cur.car
          raise SchemeRuntimeError.new("bad formal parameter: #{head.write_string}") unless head.is_a?(SchemeSym)
          params << head.name
          cur = cur.cdr
        end
        unless cur.is_a?(SchemeNil)
          raise SchemeRuntimeError.new("bad rest parameter: #{cur.write_string}") unless cur.is_a?(SchemeSym)
          rest = cur.name
        end
      else
        raise SchemeRuntimeError.new("bad formals: #{spec.write_string}")
      end
      {params, rest}
    end

    # returns {new_env, body}
    private def eval_let(rest : SchemeValue, env : Env) : {Env, Array(SchemeValue)}
      raise SchemeRuntimeError.new("let: malformed") unless rest.is_a?(Cons)
      bindings = Scheme.list_to_a(rest.car)
      body = Scheme.list_to_a(rest.cdr)
      new_env = Env.new(env)
      # evaluate all inits in OUTER env
      names = [] of String
      vals = [] of SchemeValue
      bindings.each do |binding|
        parts = Scheme.list_to_a(binding)
        raise SchemeRuntimeError.new("let: bad binding") unless parts.size == 2
        name = parts[0]
        raise SchemeRuntimeError.new("let: binding name must be symbol") unless name.is_a?(SchemeSym)
        names << name.name
        vals << eval(parts[1], env)
      end
      names.each_with_index { |name, i| new_env.define(name, vals[i]) }
      {new_env, body}
    end

    # Named let: (let name ((var init)...) body...) desugars to a
    # self-referential procedure bound in its own closure env, then an
    # immediate tail call into it — recursive calls the body makes to `name`
    # flow through the existing Lambda-tail-call path (see the "Tail call for
    # Lambda" branch below), so iteration reuses that already-stack-safe
    # trampoline instead of needing new looping machinery here.
    # Returns {call_env, body} where call_env is ready for the first
    # (tail-position) evaluation of body.
    private def eval_named_let(loop_name : SchemeSym, rest : SchemeValue, env : Env) : {Env, Array(SchemeValue)}
      raise SchemeRuntimeError.new("let: malformed") unless rest.is_a?(Cons)
      bindings = Scheme.list_to_a(rest.car)
      body = Scheme.list_to_a(rest.cdr)
      raise SchemeRuntimeError.new("let: named let body is empty") if body.empty?
      names = [] of String
      inits = [] of SchemeValue
      bindings.each do |binding|
        parts = Scheme.list_to_a(binding)
        raise SchemeRuntimeError.new("let: bad binding") unless parts.size == 2
        name = parts[0]
        raise SchemeRuntimeError.new("let: binding name must be symbol") unless name.is_a?(SchemeSym)
        names << name.name
        inits << parts[1]
      end
      # inits are evaluated in the OUTER env, same as plain let
      arg_vals = inits.map { |init| eval(init, env) }

      closure_env = Env.new(env)
      lam = Lambda.new(names, nil, body, closure_env, loop_name.name)
      closure_env.define(loop_name.name, lam)

      call_env = Env.new(closure_env)
      names.each_with_index { |name, idx| call_env.define(name, arg_vals[idx]) }
      {call_env, body}
    end

    private def eval_let_star(rest : SchemeValue, env : Env) : {Env, Array(SchemeValue)}
      raise SchemeRuntimeError.new("let*: malformed") unless rest.is_a?(Cons)
      bindings = Scheme.list_to_a(rest.car)
      body = Scheme.list_to_a(rest.cdr)
      new_env = Env.new(env)
      bindings.each do |binding|
        parts = Scheme.list_to_a(binding)
        raise SchemeRuntimeError.new("let*: bad binding") unless parts.size == 2
        name = parts[0]
        raise SchemeRuntimeError.new("let*: binding name must be symbol") unless name.is_a?(SchemeSym)
        new_env.define(name.name, eval(parts[1], new_env))
      end
      {new_env, body}
    end

    # Recognizes a cond/guard clause body of the form (=> proc) — the R7RS
    # arrow-clause shorthand — returning the unevaluated proc expression, or
    # nil if body isn't in that shape. Factored out of eval_core (rather than
    # inlined into its `cond` branch) so the extra locals needed here don't
    # inflate eval_core's own stack frame, which every recursive eval call
    # pays for — see eval_do's similar comment on this same cost.
    private def arrow_clause?(body : Array(SchemeValue)) : SchemeValue?
      return nil unless body.size == 2
      arrow = body[0]
      return nil unless arrow.is_a?(SchemeSym) && arrow.name == "=>"
      body[1]
    end

    # Evaluates a cond form's clauses against env, up to (but not including)
    # the final tail expression — entirely outside eval_core, for the same
    # stack-frame-size reason as arrow_clause? above. Returns {value, true}
    # when value is a tail expression eval_core's trampoline should continue
    # looping on, or {value, false} when value is already the cond form's
    # final result (no match, a bare-test clause, or an arrow-clause result).
    private def eval_cond(clauses_expr : SchemeValue, env : Env) : {SchemeValue, Bool}
      pos = clauses_expr.is_a?(Cons) ? clauses_expr.pos : nil
      clauses = Scheme.list_to_a(clauses_expr)
      clauses.each do |clause|
        parts = Scheme.list_to_a(clause)
        raise SchemeRuntimeError.new("cond: empty clause") if parts.empty?
        test = parts[0]
        is_else = test.is_a?(SchemeSym) && test.name == "else"
        tv = is_else ? NIL : eval(test, env)
        next unless is_else || Scheme.truthy?(tv)
        return {is_else ? NIL : tv, false} if parts.size == 1
        body = parts[1..]
        if !is_else && (receiver_expr = arrow_clause?(body))
          return {apply(eval(receiver_expr, env), [tv], pos), false}
        end
        (1...parts.size - 1).each { |i| eval(parts[i], env) }
        return {parts[parts.size - 1], true}
      end
      {NIL, false}
    end

    private def eval_letrec(rest : SchemeValue, env : Env) : {Env, Array(SchemeValue)}
      raise SchemeRuntimeError.new("letrec: malformed") unless rest.is_a?(Cons)
      bindings = Scheme.list_to_a(rest.car)
      body = Scheme.list_to_a(rest.cdr)
      new_env = Env.new(env)
      parsed = [] of {String, SchemeValue}
      bindings.each do |binding|
        parts = Scheme.list_to_a(binding)
        raise SchemeRuntimeError.new("letrec: bad binding") unless parts.size == 2
        name = parts[0]
        raise SchemeRuntimeError.new("letrec: binding name must be symbol") unless name.is_a?(SchemeSym)
        new_env.define(name.name, NIL)
        parsed << {name.name, parts[1]}
      end
      parsed.each do |name, init|
        new_env.define(name, eval(init, new_env))
      end
      {new_env, body}
    end

    # letrec* differs from letrec only in evaluation order: each binding's
    # init is evaluated and assigned immediately (interleaved), left to
    # right, rather than declaring all bindings first and batching the
    # assignments in a second pass. This lets later inits observe earlier
    # *values*, not just earlier bindings.
    private def eval_letrec_star(rest : SchemeValue, env : Env) : {Env, Array(SchemeValue)}
      raise SchemeRuntimeError.new("letrec*: malformed") unless rest.is_a?(Cons)
      bindings = Scheme.list_to_a(rest.car)
      body = Scheme.list_to_a(rest.cdr)
      new_env = Env.new(env)
      bindings.each do |binding|
        parts = Scheme.list_to_a(binding)
        raise SchemeRuntimeError.new("letrec*: bad binding") unless parts.size == 2
        name = parts[0]
        raise SchemeRuntimeError.new("letrec*: binding name must be symbol") unless name.is_a?(SchemeSym)
        new_env.define(name.name, eval(parts[1], new_env))
      end
      {new_env, body}
    end

    # Unwraps a producer expression's result for an N-way binding form
    # (let-values, let*-values, define-values): a (values a b ...) result
    # (an actual SchemeValues, per its own transparent-outside-
    # call-with-values contract — see the `values` builtin) unwraps to its
    # items; anything else is treated as a single value. Mirrors
    # call-with-values' own unwrap (builtins.cr) — kept as one shared
    # helper rather than three separate copies.
    private def values_to_a(v : SchemeValue) : Array(SchemeValue)
      v.is_a?(SchemeValues) ? v.items : [v]
    end

    # returns {new_env, body}. sequential: false = let-values (all producer
    # expressions evaluate in the OUTER env, like let); true = let*-values
    # (each sees bindings from earlier clauses, like let*).
    private def eval_let_values(rest : SchemeValue, env : Env, sequential : Bool) : {Env, Array(SchemeValue)}
      who = sequential ? "let*-values" : "let-values"
      raise SchemeRuntimeError.new("#{who}: malformed") unless rest.is_a?(Cons)
      bindings = Scheme.list_to_a(rest.car)
      body = Scheme.list_to_a(rest.cdr)
      new_env = Env.new(env)
      bindings.each do |binding|
        parts = Scheme.list_to_a(binding)
        raise SchemeRuntimeError.new("#{who}: bad binding") unless parts.size == 2
        params, rparam = parse_formals(parts[0])
        eval_env = sequential ? new_env : env
        vals = values_to_a(eval(parts[1], eval_env))
        bind_values(who, params, rparam, vals, new_env)
      end
      {new_env, body}
    end

    private def eval_define_values(rest : SchemeValue, env : Env) : SchemeValue
      parts = Scheme.list_to_a(rest)
      raise SchemeRuntimeError.new("define-values: malformed") unless parts.size == 2
      params, rparam = parse_formals(parts[0])
      vals = values_to_a(eval(parts[1], env))
      bind_values("define-values", params, rparam, vals, env)
      NIL
    end

    private def bind_values(who : String, params : Array(String), rparam : String?, vals : Array(SchemeValue), env : Env) : Nil
      if rparam
        raise SchemeRuntimeError.new("#{who}: expected at least #{params.size} value(s), got #{vals.size}") if vals.size < params.size
      else
        raise SchemeRuntimeError.new("#{who}: expected #{params.size} value(s), got #{vals.size}") if vals.size != params.size
      end
      params.each_with_index { |name, i| env.define(name, vals[i]) }
      env.define(rparam, Scheme.a_to_list(vals[params.size..])) if rparam
    end

    # (let-syntax ((name (syntax-rules ...)) ...) body...) /
    # (letrec-syntax ...) — both bind each name via the existing
    # define-syntax codepath against a child Env, differing only in whether
    # later bindings see earlier ones while being defined (matching the
    # let/letrec distinction). Since this interpreter's syntax-rules macros
    # are unhygienic and don't close over an environment the way letrec's
    # value bindings do, both forms collapse to the same implementation —
    # each binding is independently self-contained regardless of eval order.
    private def eval_let_syntax(rest : SchemeValue, env : Env) : {Env, Array(SchemeValue)}
      raise SchemeRuntimeError.new("let-syntax: malformed") unless rest.is_a?(Cons)
      bindings = Scheme.list_to_a(rest.car)
      body = Scheme.list_to_a(rest.cdr)
      new_env = Env.new(env)
      bindings.each do |binding|
        raise SchemeRuntimeError.new("let-syntax: bad binding") unless binding.is_a?(Cons)
        # eval_define_syntax expects a (define-syntax name spec) form and
        # reads its bindings from .cdr — wrap this (name spec) binding with
        # a dummy head so it fits that shape without duplicating its parsing.
        eval_define_syntax(Cons.new(SchemeSym.of("define-syntax"), binding), new_env)
      end
      {new_env, body}
    end

    # (cond-expand (requirement body...) ... [(else body...)]). requirement
    # is a feature identifier, (library (name...)), or (and/or/not ...)
    # combination thereof — evaluated immediately (no separate compile
    # phase in this interpreter) against Interpreter#features/@libraries.
    private def eval_cond_expand(rest : SchemeValue, env : Env) : SchemeValue
      Scheme.list_to_a(rest).each do |clause|
        parts = Scheme.list_to_a(clause)
        raise SchemeRuntimeError.new("cond-expand: bad clause") if parts.empty?
        requirement = parts[0]
        matched = (requirement.is_a?(SchemeSym) && requirement.name == "else") || cond_expand_matches?(requirement)
        next unless matched
        result : SchemeValue = NIL
        parts[1..].each { |form| result = eval(form, env) }
        return result
      end
      NIL
    end

    private def cond_expand_matches?(requirement : SchemeValue) : Bool
      case requirement
      when SchemeSym
        features.includes?(requirement.name)
      when Cons
        head = requirement.car
        raise SchemeRuntimeError.new("cond-expand: bad requirement") unless head.is_a?(SchemeSym)
        args = Scheme.list_to_a(requirement.cdr)
        case head.name
        when "and" then args.all? { |arg| cond_expand_matches?(arg) }
        when "or"  then args.any? { |arg| cond_expand_matches?(arg) }
        when "not"
          raise SchemeRuntimeError.new("cond-expand: not expects 1 argument") unless args.size == 1
          !cond_expand_matches?(args[0])
        when "library"
          raise SchemeRuntimeError.new("cond-expand: library expects 1 argument") unless args.size == 1
          @libraries.has_key?(SchemeLibrary.parse_library_name(args[0]))
        else
          raise SchemeRuntimeError.new("cond-expand: unknown requirement '#{head.name}'")
        end
      else
        raise SchemeRuntimeError.new("cond-expand: bad requirement #{requirement.write_string}")
      end
    end

    # Feature identifiers this interpreter satisfies for cond-expand's
    # feature-identifier requirement form (distinct from the `features`
    # base-library procedure, which returns this same list as a Scheme
    # value — see builtins.cr).
    def features : Array(String)
      %w[r7rs creme creme.cr]
    end

    # (do ((var init step)...) (test result...) command...). Runs the whole
    # iteration here (not in eval_core's own frame) so the do-loop's parsing
    # locals and per-iteration temporaries don't inflate the stack frame that
    # every recursive `eval` call pays for — eval_core must stay as lean as
    # possible since @max_eval_depth's safety margin against a real stack
    # overflow is sized against that frame's cost.
    # Returns {iter_env, result_exprs}: iter_env is ready for the (tail
    # position) evaluation of result_exprs by the caller.
    private def eval_do(rest : SchemeValue, env : Env) : {Env, Array(SchemeValue)}
      do_rest = Scheme.list_to_a(rest)
      raise SchemeRuntimeError.new("do: expects bindings and a test clause") if do_rest.size < 2
      specs = Scheme.list_to_a(do_rest[0]).map do |binding|
        parts = Scheme.list_to_a(binding)
        raise SchemeRuntimeError.new("do: bad binding") unless parts.size == 2 || parts.size == 3
        name = parts[0]
        raise SchemeRuntimeError.new("do: binding name must be symbol") unless name.is_a?(SchemeSym)
        {name.name, parts[1], parts.size == 3 ? parts[2] : nil}
      end
      test_clause = Scheme.list_to_a(do_rest[1])
      raise SchemeRuntimeError.new("do: empty test clause") if test_clause.empty?
      test_expr = test_clause[0]
      result_exprs = test_clause[1..]
      commands = do_rest[2..]

      iter_env = Env.new(env)
      specs.each { |name, init, _| iter_env.define(name, eval(init, env)) }

      loop do
        break if Scheme.truthy?(eval(test_expr, iter_env))
        commands.each { |command| eval(command, iter_env) }
        next_vals = specs.map { |name, _, step| step ? eval(step, iter_env) : iter_env.get(name) }
        next_env = Env.new(env)
        specs.each_with_index { |(name, _, _), idx| next_env.define(name, next_vals[idx]) }
        iter_env = next_env
      end

      {iter_env, result_exprs}
    end

    # (parameterize ((param val)...) body...). Dynamically rebinds each
    # parameter for body's extent, restoring the saved values in `ensure` so
    # they're put back even if body raises. That restoration is exactly why
    # this can't hand its last form to eval_core's trampoline in tail
    # position: the ensure has to run before returning to the caller, same
    # as any real Scheme implementation's parameterize can't tail-call out
    # of a dynamic-wind-protected body. call/cc now exists (see call_cc in
    # builtins.cr), and this `ensure` already correctly restores parameter
    # values when a continuation invocation unwinds through it — Crystal's
    # `ensure` doesn't care which exception subclass is passing through.
    # What's still missing is dynamic-wind itself (no before/after-thunk
    # hooks yet) and rebuilding parameterize on top of it, which only
    # matters for the full R7RS interaction between parameterize and
    # re-entrant (not just escape) continuations — out of scope until
    # call/cc grows beyond escape-only.
    private def eval_parameterize(rest : SchemeValue, env : Env) : SchemeValue
      parts = Scheme.list_to_a(rest)
      raise SchemeRuntimeError.new("parameterize: malformed") if parts.empty?
      bindings = Scheme.list_to_a(parts[0]).map do |binding|
        binding_parts = Scheme.list_to_a(binding)
        raise SchemeRuntimeError.new("parameterize: bad binding") unless binding_parts.size == 2
        param = eval(binding_parts[0], env)
        raise SchemeRuntimeError.new("parameterize: expected a parameter object") unless param.is_a?(SchemeParameter)
        {param, binding_parts[1]}.as({SchemeParameter, SchemeValue})
      end
      body = parts[1..]

      saved = bindings.map { |param, _| param.value }
      bindings.each do |param, val_expr|
        raw = eval(val_expr, env)
        converter = param.converter
        param.value = converter ? apply(converter, [raw]) : raw
      end
      begin
        result : SchemeValue = NIL
        body.each { |form| result = eval(form, env) }
        result
      ensure
        bindings.each_with_index { |(param, _), idx| param.value = saved[idx] }
      end
    end

    # (guard (var clause...) body...). Like parameterize, this can't hand
    # its result to eval_core's trampoline in tail position: the rescue
    # boundary has to stay in effect for the entire body, so tail-calling
    # out of it would evaluate the "tail" form unprotected, defeating guard.
    #
    # SchemeExit is never rescued here (it isn't a SchemeError at all, so it
    # already propagates through unmatched — process-exit intent). Nor is
    # SchemeExecutionLimitError: it's a host-configured resource budget, not
    # a guest-level condition, and letting guard swallow it would let a
    # script's own handler run more code past the very ceiling meant to
    # bound that script. ContinuationInvoked (call/cc's escape mechanism,
    # see builtins.cr's call_cc) is the same story as SchemeExit: not a
    # SchemeError, so it already passes through here untouched — a
    # continuation invoked inside a guard body correctly unwinds past the
    # guard rather than being caught by it.
    private def eval_guard(rest : SchemeValue, env : Env) : SchemeValue
      parts = Scheme.list_to_a(rest)
      raise SchemeRuntimeError.new("guard: malformed") if parts.empty?
      spec = Scheme.list_to_a(parts[0])
      raise SchemeRuntimeError.new("guard: malformed clause spec") if spec.empty?
      var = spec[0]
      raise SchemeRuntimeError.new("guard: variable must be a symbol") unless var.is_a?(SchemeSym)
      clauses = spec[1..]
      body = parts[1..]

      begin
        result : SchemeValue = NIL
        body.each { |form| result = eval(form, env) }
        result
      rescue ex : SchemeExecutionLimitError
        raise ex
      rescue ex : SchemeError
        handler_env = Env.new(env)
        condition = ex.payload || SchemeRecord.new(CONDITION_TYPE, [SchemeStr.new(ex.message || "error"), NIL] of SchemeValue)
        handler_env.define(var.name, condition)
        match_guard_clauses(clauses, handler_env) { raise ex }
      end
    end

    # Evaluates `clauses` in cond-clause style (test, else, one-form-returns-
    # the-test-value) against `handler_env`, returning the first match's
    # result. Calls `no_match` (expected to raise) if nothing matches.
    private def match_guard_clauses(clauses : Array(SchemeValue), handler_env : Env, &no_match : -> SchemeValue) : SchemeValue
      clauses.each do |clause|
        clause_parts = Scheme.list_to_a(clause)
        raise SchemeRuntimeError.new("guard: empty clause") if clause_parts.empty?
        test = clause_parts[0]
        is_else = test.is_a?(SchemeSym) && test.name == "else"
        tv = is_else ? NIL : eval(test, handler_env)
        next unless is_else || Scheme.truthy?(tv)
        return tv if clause_parts.size == 1 && !is_else
        body = clause_parts[1..]
        if !is_else && (matched_arrow = arrow_clause?(body))
          return apply(eval(matched_arrow, handler_env), [tv])
        end
        result : SchemeValue = NIL
        body.each { |form| result = eval(form, handler_env) }
        return result
      end
      no_match.call
    end

    # ---- Quasiquote -----------------------------------------------------------

    # ameba:disable Metrics/CyclomaticComplexity
    def expand_qq(tmpl : SchemeValue, env : Env, depth : Int32) : SchemeValue
      return expand_qq_vector(tmpl, env, depth) if tmpl.is_a?(SchemeVector)

      unless tmpl.is_a?(Cons)
        return tmpl
      end

      head = tmpl.car
      if head.is_a?(SchemeSym)
        case head.name
        when "unquote"
          inner = Scheme.list_to_a(tmpl.cdr)
          raise SchemeRuntimeError.new("unquote: expects 1 argument") unless inner.size == 1
          if depth == 1
            return eval(inner[0], env)
          else
            return Scheme.a_to_list([SchemeSym.of("unquote"), expand_qq(inner[0], env, depth - 1)] of SchemeValue)
          end
        when "quasiquote"
          inner = Scheme.list_to_a(tmpl.cdr)
          raise SchemeRuntimeError.new("quasiquote: expects 1 argument") unless inner.size == 1
          return Scheme.a_to_list([SchemeSym.of("quasiquote"), expand_qq(inner[0], env, depth + 1)] of SchemeValue)
        else
          # fall through
        end
      end

      # rebuild list honoring splicing in car position
      result_items = [] of SchemeValue
      cur : SchemeValue = tmpl
      tail : SchemeValue = NIL
      while cur.is_a?(Cons)
        elem = cur.car
        if elem.is_a?(Cons) && (eh = elem.car).is_a?(SchemeSym) && eh.name == "unquote-splicing" && depth == 1
          spliced_form = Scheme.list_to_a(elem.cdr)
          raise SchemeRuntimeError.new("unquote-splicing: expects 1 argument") unless spliced_form.size == 1
          spliced = eval(spliced_form[0], env)
          Scheme.list_to_a(spliced).each { |x| result_items << x }
          cur = cur.cdr
        elsif elem.is_a?(Cons) && (eh2 = elem.car).is_a?(SchemeSym) && eh2.name == "unquote-splicing"
          # deeper depth: rebuild
          inner = Scheme.list_to_a(elem.cdr)
          result_items << Scheme.a_to_list([SchemeSym.of("unquote-splicing"), expand_qq(inner[0], env, depth - 1)] of SchemeValue)
          cur = cur.cdr
        else
          # check if cdr is an unquote form (dotted unquote): `(a . ,b)
          cdr = cur.cdr
          if cdr.is_a?(Cons) && (ch = cdr.car).is_a?(SchemeSym) && ch.name == "unquote" && depth == 1
            result_items << expand_qq(elem, env, depth)
            uq = Scheme.list_to_a(cdr.cdr)
            raise SchemeRuntimeError.new("unquote: expects 1 argument") unless uq.size == 1
            tail = eval(uq[0], env)
            cur = NIL
            break
          end
          result_items << expand_qq(elem, env, depth)
          cur = cur.cdr
        end
      end
      unless cur.is_a?(SchemeNil)
        tail = expand_qq(cur, env, depth)
      end
      Scheme.a_to_list(result_items, tail)
    end

    # Vector quasiquote templates (e.g. `#(1 ,(+ 1 1) ,@(list 3 4))) walk
    # each element the same way expand_qq's list-rebuild loop above does,
    # splicing unquote-splicing results in place — just building a flat
    # Array(SchemeValue) instead of a cons spine.
    private def expand_qq_vector(tmpl : SchemeVector, env : Env, depth : Int32) : SchemeValue
      result_items = [] of SchemeValue
      tmpl.value.each do |elem|
        if elem.is_a?(Cons) && (eh = elem.car).is_a?(SchemeSym) && eh.name == "unquote-splicing" && depth == 1
          spliced_form = Scheme.list_to_a(elem.cdr)
          raise SchemeRuntimeError.new("unquote-splicing: expects 1 argument") unless spliced_form.size == 1
          spliced = eval(spliced_form[0], env)
          Scheme.list_to_a(spliced).each { |x| result_items << x }
        elsif elem.is_a?(Cons) && (eh2 = elem.car).is_a?(SchemeSym) && eh2.name == "unquote-splicing"
          inner = Scheme.list_to_a(elem.cdr)
          result_items << Scheme.a_to_list([SchemeSym.of("unquote-splicing"), expand_qq(inner[0], env, depth - 1)] of SchemeValue)
        else
          result_items << expand_qq(elem, env, depth)
        end
      end
      SchemeVector.new(result_items)
    end
  end
end
