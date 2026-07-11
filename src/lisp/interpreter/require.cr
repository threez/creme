# ===========================================================================
# require: lazy, namespaced stdlib module loading
# ===========================================================================

module LISP
  class Interpreter
    private def eval_require(expr : Cons, env : Env) : LispValue
      args = LISP.list_to_a(expr.cdr)
      raise LispRuntimeError.new("require: expects 1 argument") unless args.size == 1
      arg = args[0]
      if arg.is_a?(Cons) && (h = arg.car).is_a?(LispSym) && h.name == "quote"
        quoted = LISP.list_to_a(arg.cdr)
        arg = quoted[0] if quoted.size == 1
      end
      case arg
      when LispSym
        require_module(arg.name)
      when LispStr
        require_path(arg.value)
      else
        raise LispRuntimeError.new("require: argument must be a symbol or a string path")
      end
      arg
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
        "format"     => ->install_format(Env),
        "random"     => ->install_random(Env),
        "digest"     => ->install_digest(Env),
        "env"        => ->install_env(Env),
        "process"    => ->install_process(Env),
        "sql"        => ->install_sql(Env),
        "clos"       => ->install_clos(Env),
        "tui"        => ->install_tui(Env),
        "rfc8439"    => ->install_rfc8439(Env),
      } of String => (Env -> Nil)
    end

    # All module names the interpreter knows how to (require ...), regardless
    # of `allowed_modules`. Includes both Crystal-native modules and any
    # "#{name}.lisp" file discoverable in module_search_path. Useful for
    # building a deny-list-style allowlist, e.g.
    # `interp.available_modules - ["process", "file", "sql", "env"]`.
    def available_modules : Array(String)
      names = module_installers.keys.to_a
      @module_search_path.each do |dir|
        Dir.glob(File.join(dir, "*.lisp")).each { |file| names << File.basename(file, ".lisp") }
      end
      names.uniq
    end

    # Used by LISP.run_file so a relative (require "...") inside a top-level
    # script resolves against the script's own directory, matching how a
    # required file's own relative requires resolve against its directory.
    def push_load_dir(dir : String) : Nil
      @load_dirs << dir
    end

    def pop_load_dir : Nil
      @load_dirs.pop?
    end

    private def require_module(name : String) : Nil
      return if @packages.has_key?(name)
      if (allowed = @allowed_modules) && !allowed.includes?(name)
        raise LispRuntimeError.new("require: module '#{name}' is not permitted")
      end
      if installer = module_installers[name]?
        pkg_env = Env.new
        installer.call(pkg_env)
        @packages[name] = pkg_env
        return
      end
      if candidate = find_in_module_search_path(name)
        load_lisp_module(name, File.realpath(candidate))
        return
      end
      raise LispRuntimeError.new("require: unknown module '#{name}'")
    end

    # Searches module_search_path (in order) for a "#{name}.lisp" file —
    # e.g. modules/sxql.lisp — for a bare-symbol (require 'name) that isn't
    # a Crystal-native module.
    private def find_in_module_search_path(name : String) : String?
      @module_search_path.each do |dir|
        candidate = File.join(dir, "#{name}.lisp")
        return candidate if File.exists?(candidate)
      end
      nil
    end

    # Loads a plain .lisp file as a namespaced module — the Lisp-authored
    # counterpart to the Crystal-native modules above. Unlike those (which get
    # a parentless Env so they can't see prelude/global bindings), a Lisp
    # module's env chains to @global so its own code can use car/map/assoc/etc.
    # Shared by require_path (explicit "(require "...")" paths) and
    # find_in_module_search_path (bare-symbol requires resolved by name).
    private def load_lisp_module(name : String, resolved : String) : Nil
      if @packages.has_key?(name)
        existing_source = @package_sources[name]?
        return if existing_source == resolved
        raise LispRuntimeError.new("require: module '#{name}' already bound to #{existing_source || "a built-in module"}")
      end

      pkg_env = Env.new(@global)
      @load_dirs << File.dirname(resolved)
      begin
        LISP.run_source(self, File.read(resolved), nil, pkg_env, source_name: resolved)
      ensure
        @load_dirs.pop
      end
      @packages[name] = pkg_env
      @package_sources[name] = resolved
    end

    private def require_path(requested : String) : Nil
      base_dir = @load_dirs.last? || Dir.current
      expanded = File.expand_path(requested, base_dir)
      raise LispRuntimeError.new("require: file not found: #{requested}") unless File.exists?(expanded)
      resolved = File.realpath(expanded)

      if allowed = @module_load_paths
        permitted = allowed.any? do |dir|
          real_dir = begin
            File.realpath(dir)
          rescue File::Error
            nil
          end
          next false unless real_dir
          resolved == real_dir || resolved.starts_with?(real_dir.chomp(File::SEPARATOR) + File::SEPARATOR)
        end
        raise LispRuntimeError.new("require: path '#{requested}' is not permitted") unless permitted
      end

      name = File.basename(resolved, ".lisp")
      load_lisp_module(name, resolved)
    end
  end
end
