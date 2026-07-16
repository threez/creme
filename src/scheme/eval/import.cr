# ===========================================================================
# define-library / import — R7RS §5.6 library system
# ===========================================================================
#
# Supported grammar:
#   (define-library (name segment ...)
#     (export export-spec ...)      ; export-spec = identifier | (rename internal external)
#     (import import-set ...)
#     (begin command-or-definition ...)
#     (include filename ...) (include-ci filename ...)
#     (cond-expand cond-expand-clause ...))
#
# `import` is also legal as a standalone top-level form, using the same
# import-set grammar (only/except/prefix/rename — see library.cr).
#
# Each library gets its own fresh Env (no parent) populated by evaluating its
# begin/include bodies against it — `define` already just calls
# `env.define` against whatever Env it's handed (see eval_define), so this
# needs no new Env capability. The one deliberate exception is (scheme base)
# (and (scheme write)), whose Env *is* @base_env itself — see
# modules/scheme/base.cr. @global (the top-level program's own root
# Env, separate from @base_env) only sees (scheme base)/(scheme write)
# bindings if Interpreter.new(auto_import_base: true) (the default) copies
# them in at construction, or the program itself imports them.
#
# `include`/`include-ci`/`cond-expand` inside a library body are stubbed here
# to raise "not yet implemented" until later stages (cond-expand: stage 3,
# include/include-ci: stage 11) add real support — this keeps the grammar
# parser honest about what it recognizes without silently misparsing.

module Scheme
  class Interpreter
    # Registers a library from an already-built Env + exports table, without
    # going through source text — the mechanism (scheme base) uses to wrap
    # @base_env itself as a library (see modules/scheme/base.cr), and
    # generally useful for a host embedding this interpreter to expose its
    # own Crystal-native libraries the same way the R7RS standard/`(list
    # ...)` libraries do.
    def register_library(name : Array(String), env : Env, exports : Hash(String, String)) : SchemeLibrary
      library = SchemeLibrary.new(name, env, exports)
      @libraries[name] = library
      library
    end

    # Every library name the interpreter currently knows about (space-joined,
    # e.g. "list sql", "scheme base") — everything registered so far, whether
    # via a Crystal-native installer or a previously-imported .sld file.
    # Doesn't enumerate not-yet-imported file-based libraries discoverable
    # under library_search_path (unlike the old require-era
    # available_modules, which eagerly globbed *.scm — .sld resolution is
    # by exact name, not directory listing, so there's nothing to glob).
    # Useful for building a deny-list-style allowlist, e.g.
    # `interp.available_libraries - ["list process", "list file", "list sql", "list env"]`.
    def available_libraries : Array(String)
      @libraries.keys.map { |name| SchemeLibrary.library_name_string(name) }
    end

    # Used by Scheme.run_file so a relative path inside a top-level script
    # (e.g. a future relative-path library form) resolves against the
    # script's own directory rather than the process's CWD. @load_dirs is
    # also pushed/popped by load_library_file below, for the same reason
    # when a .sld file itself has nested relative resolution needs.
    def push_load_dir(dir : String) : Nil
      @load_dirs << dir
    end

    def pop_load_dir : Nil
      @load_dirs.pop?
    end

    def eval_define_library(expr : Cons, env : Env) : SchemeValue
      parts = Scheme.list_to_a(expr.cdr)
      raise SchemeRuntimeError.new("define-library: malformed") if parts.empty?
      name = SchemeLibrary.parse_library_name(parts[0])

      return parts[0] if @libraries.has_key?(name)
      raise SchemeRuntimeError.new("import: circular library dependency: (#{SchemeLibrary.library_name_string(name)})") if @libraries_loading.includes?(name)

      @libraries_loading << name
      begin
        build_library(name, parts[1..])
      ensure
        @libraries_loading.delete(name)
      end
      parts[0]
    end

    # Processes each declaration form into lib_env/export_specs. A
    # cond-expand declaration is not itself a member of the grammar's
    # top-level result — it's resolved immediately by splicing its matched
    # clause's own declarations back through this same method (recursively),
    # exactly as if they'd appeared inline in the library body at that
    # position — so include/import/begin/etc. nested inside a matched
    # cond-expand clause work the same as everywhere else.
    private def process_library_declarations(declarations : Array(SchemeValue), lib_env : Env, export_specs : Array(SchemeValue)) : Nil
      declarations.each do |decl|
        raise SchemeRuntimeError.new("define-library: bad declaration #{decl.write_string}") unless decl.is_a?(Cons)
        tag = decl.car
        raise SchemeRuntimeError.new("define-library: bad declaration #{decl.write_string}") unless tag.is_a?(SchemeSym)
        args = Scheme.list_to_a(decl.cdr)
        case tag.name
        when "export"
          export_specs.concat(args)
        when "import"
          args.each { |import_set| import_into(lib_env, import_set) }
        when "begin"
          BytecodeCompiler.run_program(self, args, lib_env)
        when "include", "include-ci"
          fold_case = tag.name == "include-ci"
          args.each do |filename_form|
            raise SchemeRuntimeError.new("define-library: #{tag.name} expects string filenames") unless filename_form.is_a?(SchemeStr)
            include_file(filename_form.value, lib_env, fold_case)
          end
        when "cond-expand"
          process_library_declarations(matched_cond_expand_declarations(args), lib_env, export_specs)
        else
          raise SchemeRuntimeError.new("define-library: unknown declaration '#{tag.name}'")
        end
      end
    end

    # Finds the first ce-clause among a library's cond-expand declaration
    # whose feature requirement is satisfied (or is `else`), mirroring
    # eval_cond_expand's expression-level semantics — but returns the
    # matched clause's own declaration forms (to be spliced back into the
    # enclosing declaration list) instead of evaluating them as expressions.
    private def matched_cond_expand_declarations(clauses : Array(SchemeValue)) : Array(SchemeValue)
      clauses.each do |clause|
        parts = Scheme.list_to_a(clause)
        raise SchemeRuntimeError.new("define-library: cond-expand: bad clause") if parts.empty?
        requirement = parts[0]
        matched = (requirement.is_a?(SchemeSym) && requirement.name == "else") || cond_expand_matches?(requirement)
        return parts[1..] if matched
      end
      [] of SchemeValue
    end

    # Resolves filename against the current load directory (matching
    # load_library_file's own relative-path convention) and reads it as a
    # sequence of top-level forms, without evaluating them — the shared
    # read-only half used both by define-library's include/include-ci
    # declarations (include_file below evaluates the forms against the
    # library's own Env) and by the standalone include/include-ci
    # expression type (analyze_include below reads the forms and analyzes
    # them inline into a BeginNode — the same way begin's own body is
    # handled). include-ci additionally case-folds the source text before
    # lexing, matching #!fold-case's documented effect. Pushes/pops the
    # resolved file's own directory onto @load_dirs for the duration of the
    # yielded block, so relative paths nested inside the included file (a
    # further include, or a relative import) resolve correctly.
    private def read_include_file(filename : String, fold_case : Bool, &) : Nil
      dir = @load_dirs.last?
      path = dir ? File.join(dir, filename) : filename
      raise SchemeRuntimeError.new("include: #{filename}: file not found") unless File.exists?(path)
      resolved = File.realpath(path)
      source = File.read(resolved)
      source = source.downcase if fold_case
      forms = Reader.read_all(source, resolved)
      @load_dirs << File.dirname(resolved)
      begin
        yield forms
      ensure
        @load_dirs.pop
      end
    end

    # define-library's include/include-ci declaration: reads filename's
    # forms and evaluates each against lib_env, as if they'd appeared
    # inline in a begin declaration at this position.
    private def include_file(filename : String, lib_env : Env, fold_case : Bool) : Nil
      read_include_file(filename, fold_case) { |forms| BytecodeCompiler.run_program(self, forms, lib_env) }
    end

    # The standalone include/include-ci expression type (§4.1.7): reads and
    # concatenates every named file's forms into one array, which analyze_include
    # analyzes inline into a BeginNode — "the include or include-ci expression"
    # is replaced by "a begin expression containing what was read from the
    # files," per R7RS's own wording.
    private def eval_include(filenames : Array(SchemeValue), fold_case : Bool) : Array(SchemeValue)
      all_forms = [] of SchemeValue
      filenames.each do |filename_form|
        raise SchemeRuntimeError.new("include: expects string filenames") unless filename_form.is_a?(SchemeStr)
        read_include_file(filename_form.value, fold_case) { |forms| all_forms.concat(forms) }
      end
      all_forms
    end

    # Builds and registers a library from its declaration forms, evaluating
    # begin-bodies against a fresh Env. Shared by eval_define_library (inline
    # forms) and load_library_file (a single define-library per .sld file).
    #
    # The Env is deliberately parentless — a library body sees ONLY what it
    # explicitly (import ...)s, same as any other Scheme binding it defines
    # itself. This is required for R7RS's own idioms to work correctly, e.g.
    # (import (except (scheme base) set!) (rename ... (put! set!))) only
    # makes sense if `set!` isn't still reachable through some fallback
    # parent chain after being excluded — an implicit @global parent would
    # silently defeat `except`/`rename` import-set exclusions. A library
    # that wants +/car/display/etc. must (import (scheme base)) (and
    # (scheme write)) explicitly, exactly like the R7RS spec's own examples.
    private def build_library(name : Array(String), declarations : Array(SchemeValue)) : SchemeLibrary
      lib_env = Env.new
      export_specs = [] of SchemeValue
      process_library_declarations(declarations, lib_env, export_specs)

      exports = {} of String => String
      export_specs.each do |spec|
        case spec
        when SchemeSym
          exports[spec.name] = spec.name
        when Cons
          rename_parts = Scheme.list_to_a(spec)
          unless rename_parts.size == 3 && (r = rename_parts[0]).is_a?(SchemeSym) && r.name == "rename" &&
                 (internal = rename_parts[1]).is_a?(SchemeSym) && (external = rename_parts[2]).is_a?(SchemeSym)
            raise SchemeRuntimeError.new("define-library: bad export spec #{spec.write_string}")
          end
          exports[external.name] = internal.name
        else
          raise SchemeRuntimeError.new("define-library: bad export spec #{spec.write_string}")
        end
      end

      register_library(name, lib_env, exports)
    end

    def eval_import(expr : Cons, env : Env) : SchemeValue
      Scheme.list_to_a(expr.cdr).each { |import_set| import_into(env, import_set) }
      NIL
    end

    def import_into(into : Env, import_set : SchemeValue) : Nil
      resolved = SchemeLibrary.resolve_import_set(import_set) { |name| resolve_library(name) }
      SchemeLibrary.import_bindings(into, resolved)
    end

    private def resolve_library(name : Array(String)) : SchemeLibrary
      if (allowed = @allowed_libraries) && !allowed.includes?(SchemeLibrary.library_name_string(name))
        raise SchemeRuntimeError.new("import: library (#{SchemeLibrary.library_name_string(name)}) is not permitted")
      end
      @libraries[name]? || load_library_file(name) ||
        raise SchemeRuntimeError.new("import: unknown library (#{SchemeLibrary.library_name_string(name)})")
    end

    # Resolves (a b c) -> "a/b/c.sld" searched across @library_search_path,
    # parallel to require.cr's find_in_module_search_path/load_scheme_module.
    # A .sld file must contain exactly one top-level (define-library ...)
    # form whose name matches the requested name.
    private def load_library_file(name : Array(String)) : SchemeLibrary?
      relative = File.join(name) + ".sld"
      path = @library_search_path.each do |dir|
        candidate = File.join(dir, relative)
        break candidate if File.exists?(candidate)
      end
      return nil unless path.is_a?(String)
      resolved = File.realpath(path)

      raise SchemeRuntimeError.new("import: circular library dependency: (#{SchemeLibrary.library_name_string(name)})") if @libraries_loading.includes?(name)
      @libraries_loading << name
      begin
        forms = Reader.read_all(File.read(resolved), resolved)
        raise SchemeRuntimeError.new("import: #{relative}: expected exactly one (define-library ...) form") unless forms.size == 1
        form = forms[0]
        unless form.is_a?(Cons) && (head = form.car).is_a?(SchemeSym) && head.name == "define-library"
          raise SchemeRuntimeError.new("import: #{relative}: expected a (define-library ...) form")
        end
        parts = Scheme.list_to_a(form.cdr)
        raise SchemeRuntimeError.new("import: #{relative}: malformed define-library") if parts.empty?
        file_name = SchemeLibrary.parse_library_name(parts[0])
        unless file_name == name
          raise SchemeRuntimeError.new("import: #{relative} defines library (#{SchemeLibrary.library_name_string(file_name)}), expected (#{SchemeLibrary.library_name_string(name)})")
        end

        @load_dirs << File.dirname(resolved)
        begin
          build_library(name, parts[1..])
        ensure
          @load_dirs.pop
        end
      ensure
        @libraries_loading.delete(name)
      end
    end
  end
end
