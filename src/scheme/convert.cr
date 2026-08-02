# ===========================================================================
# Crystal <-> SchemeValue conversion, for host applications embedding the
# interpreter (bindings from native data, results back as native data).
# ===========================================================================

require "json"
require "yaml"

module Scheme
  # Bytes round-trips losslessly (via SchemeBlob, never ambiguous with anything
  # else) — unlike e.g. Time, which stays one-directional (see to_scheme(Time)
  # below) since a bare SchemeFloat can't tell "timestamp" from "plain number".
  # A custom struct type can't join this closed alias, but a host can still
  # convert it one-directionally: reopen `module Scheme` and add your own
  # `def self.to_scheme(v : YourType) : SchemeValue` overload, exactly like every
  # file under src/scheme/modules/ already does to add builtins.
  alias Convertible = Nil | Bool | Int64 | Float64 | String | Bytes |
                      Array(Convertible) | Hash(String, Convertible)

  # Crystal -> SchemeValue. Overloaded per concrete type (rather than a single
  # Convertible-typed parameter) so callers can pass whatever they already
  # have without upcasting by hand. The identity overload lets a host mix
  # already-built SchemeValues (e.g. a Builtin callback) into the same
  # bindings hash as native data.
  def self.to_scheme(v : SchemeValue) : SchemeValue
    v
  end

  def self.to_scheme(v : Nil) : SchemeValue
    NIL
  end

  def self.to_scheme(v : Bool) : SchemeValue
    SchemeBool.of(v)
  end

  def self.to_scheme(v : Int) : SchemeValue
    SchemeInt.new(v.to_i64)
  end

  def self.to_scheme(v : Float) : SchemeValue
    SchemeFloat.new(v.to_f64)
  end

  def self.to_scheme(v : String) : SchemeValue
    SchemeStr.new(v)
  end

  def self.to_scheme(v : Array) : SchemeValue
    SchemeVector.new(v.map { |e| to_scheme(e).as(SchemeValue) })
  end

  # Hash(String,_) -> alist of (SchemeStr . value) pairs, matching the
  # convention already established by json.cr/sql.cr.
  def self.to_scheme(v : Hash) : SchemeValue
    Scheme.a_to_list(v.map { |k, val| Cons.new(SchemeStr.new(k.to_s), to_scheme(val)).as(SchemeValue) })
  end

  def self.to_scheme(v : JSON::Any) : SchemeValue
    to_scheme(v.raw)
  end

  # YAML::Any#raw is the same Hash/Array/scalar shape JSON::Any#raw is
  # (Hash keyed by YAML::Any rather than String -- the generic
  # to_scheme(Hash) overload above already coerces any key via `k.to_s`,
  # which round-trips a YAML::Any scalar key back to its plain text).
  def self.to_scheme(v : YAML::Any) : SchemeValue
    to_scheme(v.raw)
  end

  # One-directional: this dialect has no SchemeTime, every time value is a bare
  # epoch-second SchemeFloat (see modules/time.cr's current-time/time_from_epoch),
  # so from_scheme can't distinguish a converted Time from an ordinary float.
  def self.to_scheme(v : Time) : SchemeValue
    SchemeFloat.new(v.to_unix_f)
  end

  def self.to_scheme(v : Bytes) : SchemeValue
    SchemeBlob.new(v)
  end

  # A YAML "!!set" decodes to a Crystal Set (of YAML::Any) rather than a
  # Hash or Array -- no Set-shaped SchemeValue exists, so it flattens to a
  # SchemeVector of its elements, same as any other sequence-shaped value.
  def self.to_scheme(v : Set) : SchemeValue
    to_scheme(v.to_a)
  end

  # SchemeValue -> Crystal, generic/unknown-shape case. NIL maps to Crystal nil
  # (matching json-read's existing null <-> NIL convention) — use
  # Scheme.list_to_a directly when a value is known to be list-shaped and an
  # empty result should read as [] rather than nil.
  # ameba:disable Metrics/CyclomaticComplexity
  def self.from_scheme(v : SchemeValue) : Convertible
    case v
    when SchemeNil   then nil
    when SchemeBool  then v.value?
    when SchemeInt   then v.value
    when SchemeFloat then v.value
    when SchemeStr   then v.value
    when SchemeChar  then v.value.to_s
    when SchemeSym   then v.name
    when SchemeBlob  then v.value
    when SchemeVector
      v.value.map { |e| from_scheme(e).as(Convertible) }
    when Cons
      unless Scheme.proper_list?(v)
        raise SchemeRuntimeError.new("from_scheme: cannot convert improper list #{v.write_string}")
      end
      elems = Scheme.list_to_a(v)
      if alist_like?(elems)
        pairs = {} of String => Convertible
        elems.each do |pair|
          entry = pair.as(Cons)
          key = entry.car.as(SchemeStr).value
          pairs[key] = from_scheme(entry.cdr) unless pairs.has_key?(key)
        end
        pairs.as(Convertible)
      else
        elems.map { |e| from_scheme(e).as(Convertible) }
      end
    else
      raise SchemeRuntimeError.new("from_scheme: cannot convert #{v.write_string} to a native value")
    end
  end

  # Mirrors json.cr's json_alist? policy (proper list, non-empty, every
  # element a (SchemeStr . value) pair) — matched deliberately, not shared,
  # since the two converters serve different, narrower value universes.
  private def self.alist_like?(elems : Array(SchemeValue)) : Bool
    !elems.empty? && elems.all? { |e| e.is_a?(Cons) && e.car.is_a?(SchemeStr) }
  end

  # Bulk-inject converted bindings into an env — the loop every embedding
  # host would otherwise write identically at every call site.
  def self.bind(env : Env, bindings : Hash) : Env
    bindings.each { |k, v| env.define(k.to_s, to_scheme(v)) }
    env
  end

  def self.bind(interp : Interpreter, bindings : Hash) : Env
    bind(Env.new(interp.global), bindings)
  end
end
