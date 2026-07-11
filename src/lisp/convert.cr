# ===========================================================================
# Crystal <-> LispValue conversion, for host applications embedding the
# interpreter (bindings from native data, results back as native data).
# ===========================================================================

require "json"

module LISP
  alias Convertible = Nil | Bool | Int64 | Float64 | String |
                      Array(Convertible) | Hash(String, Convertible)

  # Crystal -> LispValue. Overloaded per concrete type (rather than a single
  # Convertible-typed parameter) so callers can pass whatever they already
  # have without upcasting by hand. The identity overload lets a host mix
  # already-built LispValues (e.g. a Builtin callback) into the same
  # bindings hash as native data.
  def self.to_lisp(v : LispValue) : LispValue
    v
  end

  def self.to_lisp(v : Nil) : LispValue
    NIL
  end

  def self.to_lisp(v : Bool) : LispValue
    LispBool.of(v)
  end

  def self.to_lisp(v : Int) : LispValue
    LispInt.new(v.to_i64)
  end

  def self.to_lisp(v : Float) : LispValue
    LispFloat.new(v.to_f64)
  end

  def self.to_lisp(v : String) : LispValue
    LispStr.new(v)
  end

  def self.to_lisp(v : Array) : LispValue
    LispVector.new(v.map { |e| to_lisp(e).as(LispValue) })
  end

  # Hash(String,_) -> alist of (LispStr . value) pairs, matching the
  # convention already established by json.cr/sql.cr.
  def self.to_lisp(v : Hash) : LispValue
    LISP.a_to_list(v.map { |k, val| Cons.new(LispStr.new(k.to_s), to_lisp(val)).as(LispValue) })
  end

  def self.to_lisp(v : JSON::Any) : LispValue
    to_lisp(v.raw)
  end

  # LispValue -> Crystal, generic/unknown-shape case. NIL maps to Crystal nil
  # (matching json:parse's existing null <-> NIL convention) — use
  # LISP.list_to_a directly when a value is known to be list-shaped and an
  # empty result should read as [] rather than nil.
  def self.from_lisp(v : LispValue) : Convertible
    case v
    when LispNil   then nil
    when LispBool  then v.value
    when LispInt   then v.value
    when LispFloat then v.value
    when LispStr   then v.value
    when LispChar  then v.value.to_s
    when LispVector
      v.value.map { |e| from_lisp(e).as(Convertible) }
    when Cons
      unless LISP.proper_list?(v)
        raise LispRuntimeError.new("from_lisp: cannot convert improper list #{v.write_string}")
      end
      elems = LISP.list_to_a(v)
      if alist_like?(elems)
        pairs = {} of String => Convertible
        elems.each do |pair|
          entry = pair.as(Cons)
          key = entry.car.as(LispStr).value
          pairs[key] = from_lisp(entry.cdr) unless pairs.has_key?(key)
        end
        pairs.as(Convertible)
      else
        elems.map { |e| from_lisp(e).as(Convertible) }
      end
    else
      raise LispRuntimeError.new("from_lisp: cannot convert #{v.write_string} to a native value")
    end
  end

  # Mirrors json.cr's json_alist? policy (proper list, non-empty, every
  # element a (LispStr . value) pair) — matched deliberately, not shared,
  # since the two converters serve different, narrower value universes.
  private def self.alist_like?(elems : Array(LispValue)) : Bool
    !elems.empty? && elems.all? { |e| e.is_a?(Cons) && e.car.is_a?(LispStr) }
  end

  # Bulk-inject converted bindings into an env — the loop every embedding
  # host would otherwise write identically at every call site.
  def self.bind(env : Env, bindings : Hash) : Env
    bindings.each { |k, v| env.define(k.to_s, to_lisp(v)) }
    env
  end

  def self.bind(interp : Interpreter, bindings : Hash) : Env
    bind(Env.new(interp.global), bindings)
  end
end
