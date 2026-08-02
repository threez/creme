# ===========================================================================
# Environment
# ===========================================================================

module Scheme
  # Variable bindings for one lexical frame. A running closure's own locals
  # do NOT live here — those are register slots on the VM's shared stack (see
  # vm.cr); Env is used for the global/library/first-class-SchemeEnvironment
  # case. A non-root frame typically holds only a handful of bindings, so it
  # starts out backed by parallel arrays and uses a linear scan — cheaper than
  # a Hash's per-insert bucket/hash overhead at this size. A frame that grows
  # past ARRAY_THRESHOLD bindings promotes itself to a Hash once, so
  # pathological cases stay O(1) instead of O(n) forever. Root envs (no
  # parent) — @global/@base_env and every library's own env — start Hash-backed
  # directly, since those are known up front to hold hundreds of bindings where
  # linear scan would lose.
  #
  # Non-root frames start out sharing a single read-only pair of EMPTY
  # sentinel arrays rather than allocating their own: a frame that binds
  # nothing — `(let () body)`, a no-arg thunk's body that never uses internal
  # `define`, an empty `begin` scope — then costs just the Env object, not an
  # object plus two throwaway arrays that only ever forward lookups to the
  # parent. The sentinels are never mutated (lookup/has_local? only read
  # them, and `index`/`includes?` on an empty array is a trivial no-op), so
  # the hot read path stays byte-identical to owning a real empty array. The
  # first `define` that actually stores a binding swaps in freshly-owned
  # arrays (see `define`). The frame keeps its distinct lexical identity from
  # birth, so an internal define appearing later scopes correctly to this
  # frame rather than leaking into the parent.
  class Env
    getter parent : Env?

    # Once a frame's binding count exceeds this, it promotes from linear-scan
    # arrays to a Hash. Chosen well above typical lambda arity/let bindings.
    ARRAY_THRESHOLD = 8

    # Shared read-only initial storage for a freshly-created non-root frame,
    # swapped out by `define` on the first stored binding. Never mutated.
    EMPTY_NAMES  = [] of String
    EMPTY_VALUES = [] of SchemeValue

    # Bumped on every define/set! into THIS frame. The AST's GlobalRefNode
    # inline-caches a free variable's value keyed on the root env's version, so
    # a hot loop that does no top-level (re)definition keeps its global-variable
    # caches valid and skips the hash lookup entirely.
    property version : Int32 = 0

    # Direct indexed read of a value slot, for the AST's lexical addressing
    # (LocalRefNode). Returns nil if this frame is Hash-backed (promoted or
    # root) or the slot doesn't exist yet, so the caller falls back to a
    # name-keyed lookup.
    def local_at?(index : Int32) : SchemeValue?
      return nil if @hash
      vals = @values
      return nil if vals.nil? || index >= vals.size
      vals[index]
    end

    def initialize(@parent : Env? = nil)
      if @parent.nil?
        @hash = {} of String => SchemeValue
      else
        @hash = nil
      end
      @names = EMPTY_NAMES
      @values = EMPTY_VALUES
      @names_shared = false
    end

    # Fast constructor for a lambda call frame: `names` is the callee's own
    # (immutable, reused-every-call) parameter-name array and `values` is the
    # freshly-built, caller-disposable argument array — so instead of
    # allocating two fresh arrays and copying each binding in (the general
    # `Env.new(parent)` + per-param `define` path), the frame shares `names`
    # by reference and adopts `values` outright: zero array allocations and no
    # per-param linear scan. `@names_shared` records that `names` is borrowed,
    # so the first body-internal `define` that adds a *new* binding copies it
    # before appending (copy-on-write) — the borrowed array is never mutated.
    # `values` is always owned outright and appended to in place.
    def initialize(@parent : Env, @names : Array(String), @values : Array(SchemeValue), @names_shared : Bool = true)
      @hash = nil
    end

    def get(name : String) : SchemeValue
      get?(name) || raise SchemeRuntimeError.new("unbound variable: #{name}")
    end

    # Same lookup as `get`, but returns nil instead of raising when unbound —
    # for callers (e.g. defmethod's generic-function auto-vivification) that
    # need to distinguish "unbound" from "bound to something else" without
    # relying on exception message text.
    def get?(name : String) : SchemeValue?
      e : Env? = self
      while cur = e
        if v = cur.lookup_local(name)
          return v
        end
        e = cur.parent
      end
      nil
    end

    # Array-backed frames always have both @names and @values set (only
    # promote_to_hash! clears them, at the same time it sets @hash) — these
    # raise instead of silently returning nil so a violation of that
    # invariant surfaces immediately rather than as a mysterious NoMethodError.
    private def names! : Array(String)
      @names || raise "Env: array-backed frame missing names"
    end

    private def values! : Array(SchemeValue)
      @values || raise "Env: array-backed frame missing values"
    end

    # Every name bound AT THIS FRAME specifically (never walks `parent`) --
    # for introspection (creme introspection)'s `bound-names`, called on
    # `interp.global`, which has no parent, so the distinction is moot there,
    # but this must NOT walk the chain in general since it's also valid to
    # call on a non-root frame. Returns a fresh Array each call (hash.keys
    # already copies; the array-backed branch dups so the caller can never
    # mutate this frame's own @names storage).
    def local_names : Array(String)
      if hash = @hash
        hash.keys
      else
        names!.dup
      end
    end

    protected def lookup_local(name : String) : SchemeValue?
      if hash = @hash
        hash[name]?
      else
        names = names!
        idx = names.index(name)
        idx ? values![idx] : nil
      end
    end

    def define(name : String, v : SchemeValue) : SchemeValue
      @version &+= 1
      if hash = @hash
        hash[name] = v
        return v
      end
      names = names!
      values = values!
      idx = names.index(name)
      if idx
        values[idx] = v
      else
        if names.same?(EMPTY_NAMES)
          # First stored binding on a fresh frame still holding the shared
          # empty sentinels — swap in freshly-owned arrays before appending.
          names = @names = [] of String
          values = @values = [] of SchemeValue
        elsif @names_shared
          # Copy-on-write: the borrowed param-name array must never be
          # mutated (it's shared by every call to this lambda), so dup it
          # before this frame grows a binding of its own. `values` is always
          # owned, so it needs no copy.
          names = @names = names.dup
          @names_shared = false
        end
        promote_to_hash! if names.size >= ARRAY_THRESHOLD
        return define(name, v) if @hash
        names << name
        values << v
      end
      v
    end

    private def promote_to_hash! : Nil
      names = names!
      values = values!
      hash = {} of String => SchemeValue
      names.each_with_index { |name, i| hash[name] = values[i] }
      @hash = hash
      @names = nil
      @values = nil
    end

    # Sugar over define(name, Builtin.new(...)) — the idiom every module
    # (regex.cr, json.cr, sql.cr, ...) already hand-rolls via its own `reg`
    # closure. Intended for registering one host callback for the
    # interpreter's whole lifetime, e.g. on interp.global.
    def define_fn(name : String, min_arity : Int32, max_arity : Int32, &fn : Array(SchemeValue) -> SchemeValue) : SchemeValue
      define(name, Builtin.new(name, min_arity, max_arity, &fn))
    end

    def set!(name : String, v : SchemeValue) : SchemeValue
      e : Env? = self
      while cur = e
        if cur.has_local?(name)
          cur.set_local(name, v)
          return v
        end
        e = cur.parent
      end
      raise SchemeRuntimeError.new("set!: unbound variable: #{name}")
    end

    protected def has_local?(name : String) : Bool
      if hash = @hash
        hash.has_key?(name)
      else
        names!.includes?(name)
      end
    end

    protected def set_local(name : String, v : SchemeValue) : Nil
      @version &+= 1
      if hash = @hash
        hash[name] = v
      else
        names = names!
        idx = names.index(name)
        if idx
          values![idx] = v
        else
          if @names_shared
            names = @names = names.dup
            @names_shared = false
          end
          names << name
          values! << v
        end
      end
    end
  end
end
