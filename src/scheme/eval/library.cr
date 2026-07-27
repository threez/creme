# ===========================================================================
# SchemeLibrary: the (define-library ...) / (import ...) namespace model
# ===========================================================================
#
# A library is a name (e.g. ["scheme", "base"] for (scheme base)) plus its
# own Env (bindings land there via ordinary `define`, exactly like any other
# top-level Env) plus an export table mapping the external name an importer
# sees to the internal name inside the library's Env — usually identical,
# distinct only for (export (rename internal external)).
#
# `import` copies bindings by value from a library's Env into the importing
# Env at import time (not a live/aliased re-export) — matches this project's
# existing require-era "copy into the importer" mental model. See
# eval/import.cr for the special forms that populate/consume these.

module Scheme
  class SchemeLibrary
    include SchemeBaseValue
    getter name : Array(String)
    getter env : Env
    # external name -> internal name
    getter exports : Hash(String, String)

    def initialize(@name : Array(String), @env : Env, @exports : Hash(String, String) = {} of String => String)
    end

    def to_display(io : IO) : Nil
      io << "#<library:" << @name.join(" ") << '>'
    end

    # (name segment ...) -> ["segment", ...]. Also accepts a bare symbol list
    # form like `(scheme base)` parsed as a Cons chain of SchemeSym.
    #
    # Each segment is validated against a conservative identifier charset
    # (alphanumeric, -, +, ! ? * < > = _) — rejects "." and "/" outright, so
    # a segment can never resolve to "." or ".." (used to join a file path
    # for file-based libraries, see eval/import.cr's
    # load_library_file) and can't embed a path separator to escape
    # library_search_path via a single "malicious" segment either.
    def self.parse_library_name(form : SchemeValue) : Array(String)
      parts = Scheme.list_to_a(form)
      raise SchemeRuntimeError.new("library name: malformed") if parts.empty?
      parts.map do |part|
        name = case part
               when SchemeSym then part.name
               when SchemeInt then part.value.to_s
               else
                 raise SchemeRuntimeError.new("library name: bad segment #{part.write_string}")
               end
        unless name.matches?(/\A[a-zA-Z0-9_+!?*<>=-]+\z/) && name != "." && name != ".."
          raise SchemeRuntimeError.new("library name: invalid segment '#{name}'")
        end
        name
      end
    end

    def self.library_name_string(name : Array(String)) : String
      name.join(" ")
    end

    # Applies an <import set> (library-name | (only ...) | (except ...) |
    # (prefix ...) | (rename ...)) against a resolver (library name -> the
    # SchemeLibrary it names), returning the concrete {external_name,
    # source_library, internal_name} triples to copy into an importing Env.
    def self.resolve_import_set(form : SchemeValue, &resolver : Array(String) -> SchemeLibrary) : Array({String, SchemeLibrary, String})
      if form.is_a?(Cons) && (head = form.car).is_a?(SchemeSym) && %w[only except prefix rename].includes?(head.name)
        args = Scheme.list_to_a(form.cdr)
        raise SchemeRuntimeError.new("import: #{head.name}: malformed") if args.empty?
        base = resolve_import_set(args[0], &resolver)
        case head.name
        when "only"
          names = args[1..].map { |arg| sym_name(arg, "only") }
          base.select { |external, _, _| names.includes?(external) }
        when "except"
          names = args[1..].map { |arg| sym_name(arg, "except") }
          base.reject { |external, _, _| names.includes?(external) }
        when "prefix"
          raise SchemeRuntimeError.new("import: prefix: expects exactly one prefix identifier") unless args.size == 2
          prefix = sym_name(args[1], "prefix")
          base.map { |external, source_lib, internal| {"#{prefix}#{external}", source_lib, internal} }
        when "rename"
          renames = args[1..].map do |pair|
            pair_parts = Scheme.list_to_a(pair)
            raise SchemeRuntimeError.new("import: rename: malformed pair") unless pair_parts.size == 2
            {sym_name(pair_parts[0], "rename"), sym_name(pair_parts[1], "rename")}
          end.to_h
          base.map do |external, source_lib, internal|
            renamed = renames[external]?
            renamed ? {renamed, source_lib, internal} : {external, source_lib, internal}
          end
        else
          raise SchemeRuntimeError.new("import: unknown import-set form #{head.name}")
        end
      else
        source_lib = resolver.call(parse_library_name(form))
        source_lib.exports.map { |external, internal| {external, source_lib, internal} }
      end
    end

    private def self.sym_name(v : SchemeValue, who : String) : String
      raise SchemeRuntimeError.new("import: #{who}: expected an identifier") unless v.is_a?(SchemeSym)
      v.name
    end

    # Copies the resolved bindings into `into`. No-op (but still validated)
    # when `into` and a binding's source library Env are the same object —
    # a defensive guard against a caller importing a library into its own
    # backing Env (e.g. (builtin base)'s Env, @base_env — see
    # modules/scheme/base.cr) rather than a real target.
    def self.import_bindings(into : Env, resolved : Array({String, SchemeLibrary, String})) : Nil
      resolved.each do |external, source_lib, internal|
        next if into.same?(source_lib.env)
        into.define(external, source_lib.env.get(internal))
      end
    end
  end
end
