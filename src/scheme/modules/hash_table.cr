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
  class SchemeHashTable < SchemeValue
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

  class Interpreter
    private def install_hash_table(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(SchemeValue) -> SchemeValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      reg.call("make-hash-table", 0, 0, ->(_args : Array(SchemeValue)) : SchemeValue { SchemeHashTable.new.as(SchemeValue) })
      reg.call("hash-table?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(args[0].is_a?(SchemeHashTable)) })

      reg.call("hash-table-set!", 3, 3, ->(args : Array(SchemeValue)) : SchemeValue do
        h = hash_table_arg(args[0], "hash-table-set!")
        key, value = args[1], args[2]
        if idx = h.index_of(key)
          h.entries[idx] = {key, value}
        else
          h.entries << {key, value}
        end
        NIL.as(SchemeValue)
      end)

      # (hash-table-ref table key [default]) — default may be a thunk
      # (0-arg procedure, called lazily) or, for callers that don't want
      # laziness, an ordinary value works too since a non-procedure default
      # simply isn't applied — see hash_table_default below.
      reg.call("hash-table-ref", 2, 3, ->(args : Array(SchemeValue)) : SchemeValue do
        h = hash_table_arg(args[0], "hash-table-ref")
        key = args[1]
        if idx = h.index_of(key)
          h.entries[idx][1]
        elsif args.size == 3
          hash_table_default(args[2])
        else
          raise SchemeRuntimeError.new("hash-table-ref: key not found")
        end
      end)

      reg.call("hash-table-delete!", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        h = hash_table_arg(args[0], "hash-table-delete!")
        if idx = h.index_of(args[1])
          h.entries.delete_at(idx)
        end
        NIL.as(SchemeValue)
      end)

      reg.call("hash-table-contains?", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        h = hash_table_arg(args[0], "hash-table-contains?")
        SchemeBool.of(!h.index_of(args[1]).nil?)
      end)

      reg.call("hash-table-keys", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        h = hash_table_arg(args[0], "hash-table-keys")
        Scheme.a_to_list(h.entries.map { |(k, _)| k })
      end)

      reg.call("hash-table-values", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        h = hash_table_arg(args[0], "hash-table-values")
        Scheme.a_to_list(h.entries.map { |(_, v)| v })
      end)

      reg.call("hash-table->alist", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        h = hash_table_arg(args[0], "hash-table->alist")
        Scheme.a_to_list(h.entries.map { |(k, v)| Cons.new(k, v).as(SchemeValue) })
      end)
    end

    private def hash_table_arg(v : SchemeValue, who : String) : SchemeHashTable
      raise SchemeRuntimeError.new("#{who}: expected a hash table, got #{v.write_string}") unless v.is_a?(SchemeHashTable)
      v
    end

    private def hash_table_default(v : SchemeValue) : SchemeValue
      v.is_a?(Builtin) || v.is_a?(Lambda) ? apply(v, [] of SchemeValue) : v
    end
  end
end
