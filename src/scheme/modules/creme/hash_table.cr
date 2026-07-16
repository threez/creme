# ===========================================================================
# hash-table module: a simple equal?-keyed hash table.
#
# Not R7RS-small (no hash tables are mandated there), but a common practical
# need. Backed by an Array of {key, value} pairs with linear scan via
# Scheme.scheme_equal? for lookup, rather than a Crystal-native Hash (which
# keys by Crystal's own ==/hash, not Scheme equal? semantics — a Cons or
# SchemeVector key wouldn't hash/compare the way Scheme code expects).
# Correctness over performance for a first implementation; fine for the
# table sizes typical scripts create.
# ===========================================================================

module Scheme
  class SchemeHashTable
    include SchemeBaseValue
    getter entries : Array({SchemeValue, SchemeValue})

    def initialize(@entries : Array({SchemeValue, SchemeValue}) = [] of {SchemeValue, SchemeValue})
    end

    def index_of(key : SchemeValue) : Int32?
      @entries.each_with_index do |(k, _), i|
        return i if Scheme.scheme_equal?(k, key)
      end
      nil
    end

    def to_display(io : IO) : Nil
      io << "#<hash-table " << @entries.size << " entries>"
    end
  end
end

module Scheme::Builtins::HashTable
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("make-hash-table", min: 0, max: 0)]
  def make_hash_table(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeHashTable.new.as(SchemeValue)
  end

  @[Scheme::SchemeFn("hash-table?", min: 1, max: 1)]
  def hash_table_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(args[0].is_a?(SchemeHashTable))
  end

  @[Scheme::SchemeFn("hash-table-set!", min: 3, max: 3)]
  def hash_table_set(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    h = hash_table_arg(args[0], "hash-table-set!")
    key, value = args[1], args[2]
    if idx = h.index_of(key)
      h.entries[idx] = {key, value}
    else
      h.entries << {key, value}
    end
    NIL.as(SchemeValue)
  end

  # (hash-table-ref table key [default]) — default may be a thunk
  # (0-arg procedure, called lazily) or, for callers that don't want
  # laziness, an ordinary value works too since a non-procedure default
  # simply isn't applied — see hash_table_default below.
  @[Scheme::SchemeFn("hash-table-ref", min: 2, max: 3)]
  def hash_table_ref(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    h = hash_table_arg(args[0], "hash-table-ref")
    key = args[1]
    if idx = h.index_of(key)
      h.entries[idx][1]
    elsif args.size == 3
      hash_table_default(interp, args[2])
    else
      raise SchemeRuntimeError.new("hash-table-ref: key not found")
    end
  end

  @[Scheme::SchemeFn("hash-table-delete!", min: 2, max: 2)]
  def hash_table_delete(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    h = hash_table_arg(args[0], "hash-table-delete!")
    if idx = h.index_of(args[1])
      h.entries.delete_at(idx)
    end
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("hash-table-contains?", min: 2, max: 2)]
  def hash_table_contains_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    h = hash_table_arg(args[0], "hash-table-contains?")
    SchemeBool.of(!h.index_of(args[1]).nil?)
  end

  @[Scheme::SchemeFn("hash-table-keys", min: 1, max: 1)]
  def hash_table_keys(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    h = hash_table_arg(args[0], "hash-table-keys")
    Scheme.a_to_list(h.entries.map { |(k, _)| k })
  end

  @[Scheme::SchemeFn("hash-table-values", min: 1, max: 1)]
  def hash_table_values(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    h = hash_table_arg(args[0], "hash-table-values")
    Scheme.a_to_list(h.entries.map { |(_, v)| v })
  end

  @[Scheme::SchemeFn("hash-table->alist", min: 1, max: 1)]
  def hash_table_to_alist(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    h = hash_table_arg(args[0], "hash-table->alist")
    Scheme.a_to_list(h.entries.map { |(k, v)| Cons.new(k, v).as(SchemeValue) })
  end

  private def hash_table_arg(v : SchemeValue, who : String) : SchemeHashTable
    raise SchemeRuntimeError.new("#{who}: expected a hash table, got #{v.write_string}") unless v.is_a?(SchemeHashTable)
    v
  end

  private def hash_table_default(interp : Interpreter, v : SchemeValue) : SchemeValue
    callable = v.is_a?(Builtin) || v.is_a?(BytecodeClosure) || v.is_a?(BytecodeCaseClosure)
    callable ? interp.apply(v, [] of SchemeValue) : v
  end
end

module Scheme
  class Interpreter
    register_library ["creme", "hash-table"], Scheme::Builtins::HashTable
  end
end
