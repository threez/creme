# ===========================================================================
# require: lazy, namespaced stdlib module loading
# ===========================================================================

module LISP
  class Interpreter
    private def eval_require(expr : Cons, env : Env) : LispValue
      args = LISP.list_to_a(expr.cdr)
      raise LispRuntimeError.new("require: expects 1 argument") unless args.size == 1
      sym = args[0]
      if sym.is_a?(Cons) && (h = sym.car).is_a?(LispSym) && h.name == "quote"
        quoted = LISP.list_to_a(sym.cdr)
        sym = quoted[0] if quoted.size == 1
      end
      raise LispRuntimeError.new("require: argument must be a symbol") unless sym.is_a?(LispSym)
      require_module(sym.name)
      sym
    end

    private def module_installers : Hash(String, (Env -> Nil))
      {
        "bigdecimal" => ->install_bigdecimal(Env),
        "math"       => ->install_math(Env),
        "regex"      => ->install_regex(Env),
        "json"       => ->install_json(Env),
        "file"       => ->install_file(Env),
        "time"       => ->install_time(Env),
        "string"     => ->install_string_ext(Env),
        "random"     => ->install_random(Env),
        "digest"     => ->install_digest(Env),
        "env"        => ->install_env(Env),
        "process"    => ->install_process(Env),
        "sql"        => ->install_sql(Env),
        "sxql"       => ->install_sxql(Env),
      } of String => (Env -> Nil)
    end

    private def require_module(name : String) : Nil
      return if @packages.has_key?(name)
      installer = module_installers[name]?
      raise LispRuntimeError.new("require: unknown module '#{name}'") unless installer
      pkg_env = Env.new
      installer.call(pkg_env)
      @packages[name] = pkg_env
    end
  end
end
