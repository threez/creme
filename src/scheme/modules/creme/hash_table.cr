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

    def initialize(@entries : Array({SchemeValue, SchemeValue}) = [] of {SchemeValue, SchemeValue})
    end

    # Every entry-point below takes @mutex, so a table shared as a cache
    # across concurrently-running fibers (e.g. (creme memoize)'s per-wrapper
    # cache, shared by every concurrently-handled request in an HTTP app)
    # is safe under real OS-thread parallelism (-Dpreview_mt with
    # CRYSTAL_WORKERS > 1) —
    # Array#<</#[]=/#delete_at can all reallocate the shared backing store,
    # and two threads doing that at once corrupts it (this reproduced in
    # practice as a GC "duplicate large block deallocation" abort under
    # load). A no-op cost under the single-OS-thread cooperative-fiber case
    # this interpreter otherwise assumes, where mutations never truly
    # overlap. `hash_table_default`'s thunk call (which may re-enter this
    # same table) must run outside the lock — Crystal's Mutex isn't
    # reentrant — so `get?` never calls user code while held.
    @mutex = Mutex.new

    def set(key : SchemeValue, value : SchemeValue) : Nil
      @mutex.synchronize do
        if idx = unsafe_index_of(key)
          @entries[idx] = {key, value}
        else
          @entries << {key, value}
        end
      end
    end

    def get?(key : SchemeValue) : SchemeValue?
      @mutex.synchronize do
        idx = unsafe_index_of(key)
        idx ? @entries[idx][1] : nil
      end
    end

    def contains?(key : SchemeValue) : Bool
      @mutex.synchronize { !unsafe_index_of(key).nil? }
    end

    def delete(key : SchemeValue) : Nil
      @mutex.synchronize do
        idx = unsafe_index_of(key)
        @entries.delete_at(idx) if idx
      end
    end

    # A point-in-time copy, for callers (keys/values/->alist) that need to
    # iterate without holding the table locked for the whole traversal.
    def snapshot : Array({SchemeValue, SchemeValue})
      @mutex.synchronize { @entries.dup }
    end

    def size : Int32
      @mutex.synchronize { @entries.size }
    end

    private def unsafe_index_of(key : SchemeValue) : Int32?
      @entries.each_with_index do |(k, _), i|
        return i if Scheme.scheme_equal?(k, key)
      end
      nil
    end

    def to_display(io : IO) : Nil
      io << "#<hash-table " << size << " entries>"
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
    h.set(args[1], args[2])
    NIL.as(SchemeValue)
  end

  # (hash-table-ref table key [default]) — default may be a thunk
  # (0-arg procedure, called lazily) or, for callers that don't want
  # laziness, an ordinary value works too since a non-procedure default
  # simply isn't applied — see hash_table_default below. The thunk call
  # deliberately happens after the table's own lookup lock is released
  # (see SchemeHashTable's header comment).
  @[Scheme::SchemeFn("hash-table-ref", min: 2, max: 3)]
  def hash_table_ref(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    h = hash_table_arg(args[0], "hash-table-ref")
    if value = h.get?(args[1])
      value
    elsif args.size == 3
      hash_table_default(interp, args[2])
    else
      raise SchemeRuntimeError.new("hash-table-ref: key not found")
    end
  end

  @[Scheme::SchemeFn("hash-table-delete!", min: 2, max: 2)]
  def hash_table_delete(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    h = hash_table_arg(args[0], "hash-table-delete!")
    h.delete(args[1])
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("hash-table-contains?", min: 2, max: 2)]
  def hash_table_contains_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    h = hash_table_arg(args[0], "hash-table-contains?")
    SchemeBool.of(h.contains?(args[1]))
  end

  @[Scheme::SchemeFn("hash-table-keys", min: 1, max: 1)]
  def hash_table_keys(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    h = hash_table_arg(args[0], "hash-table-keys")
    Scheme.a_to_list(h.snapshot.map { |(k, _)| k })
  end

  @[Scheme::SchemeFn("hash-table-values", min: 1, max: 1)]
  def hash_table_values(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    h = hash_table_arg(args[0], "hash-table-values")
    Scheme.a_to_list(h.snapshot.map { |(_, v)| v })
  end

  @[Scheme::SchemeFn("hash-table->alist", min: 1, max: 1)]
  def hash_table_to_alist(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    h = hash_table_arg(args[0], "hash-table->alist")
    Scheme.a_to_list(h.snapshot.map { |(k, v)| Cons.new(k, v).as(SchemeValue) })
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
