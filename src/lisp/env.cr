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
      e : Env? = self
      while cur = e
        if v = cur.lookup_local(name)
          return v
        end
        e = cur.parent
      end
      raise LispRuntimeError.new("unbound variable: #{name}")
    end

    protected def lookup_local(name : String) : LispValue?
      @vars[name]?
    end

    def define(name : String, v : LispValue) : LispValue
      @vars[name] = v
      v
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
