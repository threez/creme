# ===========================================================================
# json module: parse/stringify
#
# Arrays decode to SchemeVector; objects decode to an alist of (key . value)
# conses, usable directly with assoc/cdr/set-cdr!/car.
# ===========================================================================

require "json"

module Scheme::Builtins::JsonLibrary
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("json-read", min: 1, max: 1)]
  def json_read(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    s = args[0]
    raise SchemeRuntimeError.new("json-read: expected string, got #{s.write_string}") unless s.is_a?(SchemeStr)
    Scheme.to_scheme(JSON.parse(s.value))
  rescue ex : JSON::ParseException
    raise SchemeRuntimeError.new("json-read: invalid json: #{ex.message}")
  end

  @[Scheme::SchemeFn("json-write", min: 1, max: 1)]
  def json_write_builtin(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeStr.new(JSON.build { |json| json_write(args[0], json, "json-write") })
  end

  # A Cons is written as a JSON object when it's a proper list whose every
  # element is itself a (string . value) pair — i.e. it looks like an alist
  # produced by json-read. Otherwise a proper list is written as a JSON
  # array, so plain Scheme lists round-trip through stringify too.
  private def json_alist?(v : SchemeValue) : Bool
    return false unless Scheme.proper_list?(v)
    elems = Scheme.list_to_a(v)
    return false if elems.empty?
    elems.all? { |e| e.is_a?(Cons) && e.car.is_a?(SchemeStr) }
  end

  private def json_write(v : SchemeValue, json : JSON::Builder, who : String) : Nil
    case v
    when SchemeNil
      json.null
    when SchemeBool
      json.bool(v.value?)
    when SchemeInt
      json.number(v.value)
    when SchemeFloat
      json.number(v.value)
    when SchemeStr
      json.string(v.value)
    when SchemeChar
      json.string(v.value.to_s)
    when SchemeVector
      json.array do
        v.value.each { |e| json_write(e, json, who) }
      end
    when Cons
      if json_alist?(v)
        json.object do
          Scheme.list_to_a(v).each do |pair|
            entry = pair.as(Cons)
            json.field(entry.car.as(SchemeStr).value) { json_write(entry.cdr, json, who) }
          end
        end
      else
        raise SchemeRuntimeError.new("#{who}: cannot serialize improper list") unless Scheme.proper_list?(v)
        json.array do
          Scheme.list_to_a(v).each { |e| json_write(e, json, who) }
        end
      end
    else
      raise SchemeRuntimeError.new("#{who}: cannot serialize #{v.write_string}")
    end
  end
end

module Scheme
  class Interpreter
    register_library ["creme", "json"], Scheme::Builtins::JsonLibrary
  end
end
