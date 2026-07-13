# ===========================================================================
# Environment
# ===========================================================================

module Scheme
  # Variable bindings for one lexical frame. Call-frame envs (lambda calls,
  # let/letrec/do bodies, ...) typically hold only a handful of bindings, so
  # they start out backed by parallel arrays and use a linear scan — cheaper
  # than a Hash's per-insert bucket/hash overhead at this size, and this is
  # by far the hottest allocation in eval_core's trampoline (a fresh Env per
  # call). A frame that grows past ARRAY_THRESHOLD bindings (a large let, or
  # a library/global env mistakenly constructed with a parent) promotes
  # itself to a Hash once, so pathological cases stay O(1) instead of O(n)
  # forever. Root envs (no parent) — @global/@base_env and every library's
  # own env — start Hash-backed directly, since those are known up front to
  # hold hundreds of bindings where linear scan would lose.
  class Env
    getter parent : Env?

    # Once a frame's binding count exceeds this, it promotes from linear-scan
    # arrays to a Hash. Chosen well above typical lambda arity/let bindings.
    ARRAY_THRESHOLD = 8

    def initialize(@parent : Env? = nil)
      if @parent.nil?
        @hash = {} of String => SchemeValue
        @names = nil
        @values = nil
      else
        @hash = nil
        @names = [] of String
        @values = [] of SchemeValue
      end
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

    protected def lookup_local(name : String) : SchemeValue?
      if hash = @hash
        hash[name]?
      else
        names = @names.not_nil!
        idx = names.index(name)
        idx ? @values.not_nil![idx] : nil
      end
    end

    def define(name : String, v : SchemeValue) : SchemeValue
      if hash = @hash
        hash[name] = v
        return v
      end
      names = @names.not_nil!
      values = @values.not_nil!
      idx = names.index(name)
      if idx
        values[idx] = v
      else
        promote_to_hash! if names.size >= ARRAY_THRESHOLD
        return define(name, v) if @hash
        names << name
        values << v
      end
      v
    end

    private def promote_to_hash! : Nil
      names = @names.not_nil!
      values = @values.not_nil!
      hash = {} of String => SchemeValue
      names.each_with_index { |n, i| hash[n] = values[i] }
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
        @names.not_nil!.includes?(name)
      end
    end

    protected def set_local(name : String, v : SchemeValue) : Nil
      if hash = @hash
        hash[name] = v
      else
        names = @names.not_nil!
        idx = names.index(name)
        if idx
          @values.not_nil![idx] = v
        else
          names << name
          @values.not_nil! << v
        end
      end
    end
  end
end
