# ===========================================================================
# json module: parse/stringify
#
# Arrays decode to LispVector; objects decode to an alist of (key . value)
# conses, usable directly with assoc/cdr/set-cdr!/car.
# ===========================================================================

require "json"

module LISP
  class Interpreter
    private def install_json(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(LispValue) -> LispValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      reg.call("parse", 1, 1, ->(args : Array(LispValue)) : LispValue do
        s = args[0]
        raise LispRuntimeError.new("json:parse: expected string, got #{s.write_string}") unless s.is_a?(LispStr)
        begin
          json_to_lisp(JSON.parse(s.value))
        rescue ex : JSON::ParseException
          raise LispRuntimeError.new("json:parse: invalid json: #{ex.message}")
        end
      end)

      reg.call("stringify", 1, 1, ->(args : Array(LispValue)) : LispValue do
        LispStr.new(JSON.build { |json| json_write(args[0], json, "json:stringify") })
      end)
    end

    private def json_to_lisp(any : JSON::Any) : LispValue
      raw = any.raw
      case raw
      when Nil     then NIL
      when Bool    then LispBool.of(raw)
      when Int64   then LispInt.new(raw)
      when Float64 then LispFloat.new(raw)
      when String  then LispStr.new(raw)
      when Array(JSON::Any)
        LispVector.new(raw.map { |x| json_to_lisp(x) })
      when Hash(String, JSON::Any)
        LISP.a_to_list(raw.map { |k, v| Cons.new(LispStr.new(k), json_to_lisp(v)).as(LispValue) })
      else
        raise LispRuntimeError.new("json:parse: unsupported json value")
      end
    end

    # A Cons is written as a JSON object when it's a proper list whose every
    # element is itself a (string . value) pair — i.e. it looks like an alist
    # produced by json:parse. Otherwise a proper list is written as a JSON
    # array, so plain Lisp lists round-trip through stringify too.
    private def json_alist?(v : LispValue) : Bool
      return false unless LISP.proper_list?(v)
      elems = LISP.list_to_a(v)
      return false if elems.empty?
      elems.all? { |e| e.is_a?(Cons) && e.car.is_a?(LispStr) }
    end

    private def json_write(v : LispValue, json : JSON::Builder, who : String) : Nil
      case v
      when LispNil
        json.null
      when LispBool
        json.bool(v.value)
      when LispInt
        json.number(v.value)
      when LispFloat
        json.number(v.value)
      when LispStr
        json.string(v.value)
      when LispVector
        json.array do
          v.value.each { |e| json_write(e, json, who) }
        end
      when Cons
        if json_alist?(v)
          json.object do
            LISP.list_to_a(v).each do |pair|
              entry = pair.as(Cons)
              json.field(entry.car.as(LispStr).value) { json_write(entry.cdr, json, who) }
            end
          end
        else
          raise LispRuntimeError.new("#{who}: cannot serialize improper list") unless LISP.proper_list?(v)
          json.array do
            LISP.list_to_a(v).each { |e| json_write(e, json, who) }
          end
        end
      else
        raise LispRuntimeError.new("#{who}: cannot serialize #{v.write_string}")
      end
    end
  end
end
