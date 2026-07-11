# ===========================================================================
# Environment
# ===========================================================================

module LISP
  class Env
    getter parent : Env?

    def initialize(@parent : Env? = nil)
      @vars = {} of String => LispValue
    end

    def get(name : String) : LispValue
      get?(name) || raise LispRuntimeError.new("unbound variable: #{name}")
    end

    # Same lookup as `get`, but returns nil instead of raising when unbound —
    # for callers (e.g. defmethod's generic-function auto-vivification) that
    # need to distinguish "unbound" from "bound to something else" without
    # relying on exception message text.
    def get?(name : String) : LispValue?
      e : Env? = self
      while cur = e
        if v = cur.lookup_local(name)
          return v
        end
        e = cur.parent
      end
      nil
    end

    protected def lookup_local(name : String) : LispValue?
      @vars[name]?
    end

    def define(name : String, v : LispValue) : LispValue
      @vars[name] = v
      v
    end

    # Sugar over define(name, Builtin.new(...)) — the idiom every module
    # (regex.cr, json.cr, sql.cr, ...) already hand-rolls via its own `reg`
    # closure. Intended for registering one host callback for the
    # interpreter's whole lifetime, e.g. on interp.global.
    def define_fn(name : String, min_arity : Int32, max_arity : Int32, &fn : Array(LispValue) -> LispValue) : LispValue
      define(name, Builtin.new(name, min_arity, max_arity, &fn))
    end

    def set!(name : String, v : LispValue) : LispValue
      e : Env? = self
      while cur = e
        if cur.has_local?(name)
          cur.set_local(name, v)
          return v
        end
        e = cur.parent
      end
      raise LispRuntimeError.new("set!: unbound variable: #{name}")
    end

    protected def has_local?(name : String) : Bool
      @vars.has_key?(name)
    end

    protected def set_local(name : String, v : LispValue) : Nil
      @vars[name] = v
    end
  end
end
