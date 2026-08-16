# (creme radix) — a general-purpose ":name"/"*name" prefix-matching
# radix tree, exposed directly to Scheme. Wraps the same `radix` shard
# (`luislavena/radix`) mux.cr's own `threez/mux.cr` shard already
# depends on transitively, so this is a thin frontend, not a second
# implementation of the algorithm — see icecreme/radix.c for the
# from-scratch C port this mirrors (both back (creme mux)'s own routing
# too; see mux.cr's own header comment).
#
# `Radix::Tree#add` raises `Radix::Tree::DuplicateError` on re-adding an
# exact existing pattern, but icecreme's own radix.c documents re-adding
# as a silent overwrite instead (see that file's own header comment) --
# to keep both backends behaviorally identical, `RadixTreeState` keeps
# its own `pattern -> payload` Hash (insertion order preserved) as the
# source of truth and rebuilds a fresh `Radix::Tree` from it on every
# `set` call, rather than mutating the shard's tree in place. Rebuilding
# per insert is O(n) in the route/pattern count -- fine for a one-time
# setup cost, not a per-request path.
#
# Boxed via the generic `SchemeBox` (not its own `SchemeValue` subtype),
# same as mux.cr's own `MuxApp`/`MuxServer` -- an opaque host handle,
# not a value type the rest of the interpreter needs to pattern-match
# on. See box.cr's own doc comment for why this needs no value/alias.cr
# edit at all.
require "radix"

module Creme
  class RadixTreeState
    def initialize
      @entries = Hash(String, SchemeValue).new
      @tree = Radix::Tree(SchemeValue).new
    end

    def set(pattern : String, value : SchemeValue) : Nil
      @entries[pattern] = value
      tree = Radix::Tree(SchemeValue).new
      @entries.each { |k, v| tree.add(k, v) }
      @tree = tree
    end

    def match(path : String) : {SchemeValue, Hash(String, String)}?
      result = @tree.find(path)
      return nil unless result.found?
      {result.payload, result.params}
    end

    def count : Int32
      @entries.size
    end
  end
end

module Creme::Builtins::Radix
  extend self
  include Creme::BuiltinHelpers

  @[Creme::SchemeFn("radix-tree", min: 0, max: 0)]
  def radix_tree(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBox.new("radix-tree", RadixTreeState.new, "#<radix-tree>").as(SchemeValue)
  end

  @[Creme::SchemeFn("radix-tree?", min: 1, max: 1)]
  def radix_tree_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    SchemeBool.of(v.is_a?(SchemeBox) && v.tag == "radix-tree")
  end

  @[Creme::SchemeFn("radix-tree-set!", min: 3, max: 3)]
  def radix_tree_set_bang(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    tree_arg(args[0], "radix-tree-set!").set(radix_str_arg(args[1], "radix-tree-set!"), args[2])
    NIL.as(SchemeValue)
  end

  @[Creme::SchemeFn("radix-tree-ref", min: 2, max: 2)]
  def radix_tree_ref(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    result = tree_arg(args[0], "radix-tree-ref").match(radix_str_arg(args[1], "radix-tree-ref"))
    result ? result[0] : FALSE.as(SchemeValue)
  end

  @[Creme::SchemeFn("radix-tree-match", min: 2, max: 2)]
  def radix_tree_match(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    result = tree_arg(args[0], "radix-tree-match").match(radix_str_arg(args[1], "radix-tree-match"))
    return FALSE.as(SchemeValue) unless result
    value, params = result
    pairs = params.map { |k, v| Cons.new(SchemeStr.new(k), SchemeStr.new(v)).as(SchemeValue) }
    Cons.new(value, Creme.a_to_list(pairs)).as(SchemeValue)
  end

  @[Creme::SchemeFn("radix-tree-count", min: 1, max: 1)]
  def radix_tree_count(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeInt.new(tree_arg(args[0], "radix-tree-count").count.to_i64).as(SchemeValue)
  end

  # ------------------------------------------------------------- helpers

  private def tree_arg(v : SchemeValue, who : String) : RadixTreeState
    raise SchemeRuntimeError.new("#{who}: expected a radix-tree, got #{v.write_string}") unless v.is_a?(SchemeBox) && v.tag == "radix-tree"
    v.get(RadixTreeState)
  end

  private def radix_str_arg(v : SchemeValue, who : String) : String
    raise SchemeRuntimeError.new("#{who}: expected a string, got #{v.write_string}") unless v.is_a?(SchemeStr)
    v.value
  end
end

module Creme
  class Interpreter
    register_library ["creme", "builtin", "radix"], Creme::Builtins::Radix
  end
end
