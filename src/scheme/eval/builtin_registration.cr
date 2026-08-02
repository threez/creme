# ===========================================================================
# Annotation-driven builtin registration: @[Scheme::SchemeFn(...)]
# ===========================================================================
#
# A library module (e.g. Scheme::Builtins::Predicates) declares one method
# per builtin, each annotated with its Scheme name and arity:
#
#   module Scheme::Builtins::Xxx
#     extend self
#     include Scheme::BuiltinHelpers
#
#     @[Scheme::SchemeFn("some-name", min: 1, max: 1)]
#     def some_method(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
#       ...
#     end
#   end
#
#   module Scheme
#     class Interpreter
#       register_library ["scheme", "xxx"], Scheme::Builtins::Xxx
#     end
#   end
#
# `Interpreter#register_module` scans a module's methods at compile time for
# the @[Scheme::SchemeFn] annotation and generates one `Builtin.new(...)`
# registration per match, closing over `self` (the running interpreter) and
# the target `env`, returning the Array(String) of names it just
# registered — so most libraries need no separately hand-maintained
# SCHEME_XXX_EXPORTS/CREME_XXX_EXPORTS constant at all.
#
# `register_library` is the fully declarative registration call itself —
# no separate install_xxx method, no separate wiring file. Every call site
# (scattered across every modules/scheme/*.cr and modules/creme/*.cr file)
# appends to a single compile-time list (LIB_DECLS); `macro finished` (which
# runs once, after the whole program — every file's register_library calls —
# has been parsed) turns that list into one real `install_all_libraries`
# method, called from Interpreter#initialize. Two forms:
#
# - `register_library ["scheme", "xxx"], Scheme::Builtins::Xxx` — the common
#   case: a library whose entire export surface IS one module's own
#   annotated methods.
# - `register_library ["scheme", "xxx"] { |env| ... }` — anything needing
#   more than a single register_module call: borrowed @base_env bindings,
#   extra constants (e.g. (creme math)'s pi/e — Crystal has no macro-level
#   introspection for annotations on individual constants, only on
#   types/methods/ivars, so those still need an explicit env.define here),
#   wrapping another library's installer and exporting only a subset of it,
#   or combining more than one module. The block's own last expression is
#   the Array(String) to export, same contract as the plain form.
#
# (builtin base)/(builtin write) are registered directly via
# install_builtin_libraries (called separately from Interpreter#initialize,
# before install_all_libraries) since their Env *is* @base_env itself, not a
# fresh Env the way every register_library-declared library gets. Their
# exports are still DERIVED from register_module return values (the section
# installers' names for base, install_write's for write) — the one residue
# is base.cr's BUILTIN_BASE_NONFN, the handful of exports that aren't
# annotated methods at all (syntactic keywords + the current-*-port
# parameter objects), which no register_module could report.
#
# (scheme base)/(scheme write) are themselves ordinary libraries built on
# top of (builtin base)/(builtin write) through the normal define-library
# machinery (install_scheme_base_and_write_libraries, base.cr) — they get a
# fresh Env like any other library, not @base_env.

annotation Scheme::SchemeFn
end

module Scheme
  class Interpreter
    # Compile-time-only: every register_library call anywhere in the
    # program appends {name, mod_or_nil, block_or_nil} here; macro finished
    # (below) consumes the whole list once, after every file has been
    # parsed, regardless of require order.
    LIB_DECLS = [] of Nil

    macro register_module(mod, env)
      %names = [] of String
      {% for method in mod.resolve.methods %}
        {% ann = method.annotation(Scheme::SchemeFn) %}
        {% if ann %}
          {{env}}.define({{ann[0]}}, Builtin.new({{ann[0]}}, {{ann[:min]}}, {{ann[:max]}}) do |args|
            {{mod}}.{{method.name}}(self, {{env}}, args)
          end)
          %names << {{ann[0]}}
        {% end %}
      {% end %}
      %names
    end

    macro register_library(name, mod)
      {% LIB_DECLS << {name, mod, nil} %}
    end

    macro register_library(name, &block)
      {% LIB_DECLS << {name, nil, block} %}
    end

    # Rather than eagerly constructing every native library at Interpreter
    # construction time (regardless of whether the running script ever
    # imports it — see this file's header comment), install_all_libraries
    # just stashes each entry's constructor away in @pending_libraries,
    # keyed by name; resolve_library (import.cr) actually invokes one only
    # when a program first (import ...)s that name. (creme builtin base)/
    # (creme builtin write) are the sole exception — they're registered
    # directly via install_builtin_libraries, never through this macro-
    # collected LIB_DECLS path at all, so they stay eager unconditionally.
    macro finished
      private def install_all_libraries : Nil
        {% for entry in LIB_DECLS %}
          {% name = entry[0]
             mod = entry[1]
             block = entry[2] %}
          {% if mod %}
            register_pending_library({{name}}) { |env| register_module({{mod}}, env) }
          {% else %}
            register_pending_library({{name}}) {{block}}
          {% end %}
        {% end %}
      end
    end

    # Stashes a not-yet-constructed native library's own constructor block
    # away by name, without running it. `& block : Env -> Array(String)`
    # (an explicitly-typed captured block, rather than a plain `yield`-only
    # block) is what makes the block itself storable as a Proc value here
    # instead of only usable for an immediate yield.
    private def register_pending_library(name : Array(String), &block : Env -> Array(String)) : Nil
      @pending_libraries[name] = block
    end

    # Builds a fresh Env, yields it to `block` which populates it and
    # returns the Array(String) of names that should be exported, then
    # wraps (name, env, those exports) into a registered SchemeLibrary.
    private def register_computed_library(name : Array(String), & : Env -> Array(String)) : SchemeLibrary
      env = Env.new
      exports = yield env
      register_library(name, env, exports.to_h { |export_name| {export_name, export_name} })
    end

    # Looks up an already-constructed native/file-based library, or — if
    # `name` is still sitting in @pending_libraries (a native library whose
    # LIB_DECLS-declared constructor hasn't run yet) — removes it from
    # there and actually constructs it now, caching the result in
    # @libraries exactly as if it had been built eagerly. Returns nil if
    # `name` is neither already registered nor pending (i.e. it's either a
    # file-based .sld library, not yet loaded, or genuinely unknown).
    private def construct_pending_library(name : Array(String)) : SchemeLibrary?
      if library = @libraries[name]?
        return library
      end
      ctor = @pending_libraries.delete(name)
      return nil unless ctor
      register_computed_library(name, &ctor)
    end
  end
end
