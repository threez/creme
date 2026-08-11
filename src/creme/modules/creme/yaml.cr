# ===========================================================================
# yaml module: parse/build a single YAML document
#
# Mappings decode to an alist of (key . value) conses; sequences decode to
# a SchemeVector -- the same "objects -> alist, arrays -> vector"
# convention (creme json)/(creme csv) already use. Multi-document streams
# are out of scope (same as (creme xml)/(creme matrix) each document their
# own narrower scope) -- yaml-read always reads exactly one document.
# ===========================================================================

require "yaml"

module Creme::Builtins::YamlLibrary
  extend self
  include Creme::BuiltinHelpers

  @[Creme::SchemeFn("yaml-read", min: 1, max: 1)]
  def yaml_read(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    s = args[0]
    raise SchemeRuntimeError.new("yaml-read: expected string, got #{s.write_string}") unless s.is_a?(SchemeStr)
    Creme.to_scheme(YAML.parse(s.value))
  rescue ex : YAML::ParseException
    raise SchemeRuntimeError.new("yaml-read: invalid yaml: #{ex.message}")
  end

  @[Creme::SchemeFn("yaml-write", min: 1, max: 1)]
  def yaml_write_builtin(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeStr.new(YAML.build { |yaml| yaml_write(args[0], yaml, "yaml-write") })
  end

  # A Cons is written as a YAML mapping when it's a proper list whose
  # every element is itself a (string . value) pair -- i.e. it looks like
  # an alist produced by yaml-read. Otherwise a proper list is written as
  # a YAML sequence, so plain Scheme lists round-trip through yaml-write
  # too. Matches json.cr's json_alist?/json_write dispatch exactly.
  private def yaml_alist?(v : SchemeValue) : Bool
    return false unless Creme.proper_list?(v)
    elems = Creme.list_to_a(v)
    return false if elems.empty?
    elems.all? { |e| e.is_a?(Cons) && e.car.is_a?(SchemeStr) }
  end

  # ameba:disable Metrics/CyclomaticComplexity
  private def yaml_write(v : SchemeValue, yaml : YAML::Builder, who : String) : Nil
    case v
    when SchemeNil
      yaml.scalar(nil)
    when SchemeBool
      yaml.scalar(v.value?)
    when SchemeInt
      yaml.scalar(v.value)
    when SchemeBigInt
      yaml.scalar(v.value.to_s)
    when SchemeFloat
      yaml.scalar(v.value)
    when SchemeStr
      yaml.scalar(v.value)
    when SchemeChar
      yaml.scalar(v.value.to_s)
    when SchemeVector
      yaml.sequence do
        v.value.each { |e| yaml_write(e, yaml, who) }
      end
    when Cons
      if yaml_alist?(v)
        yaml.mapping do
          Creme.list_to_a(v).each do |pair|
            entry = pair.as(Cons)
            yaml.scalar(entry.car.as(SchemeStr).value)
            yaml_write(entry.cdr, yaml, who)
          end
        end
      else
        raise SchemeRuntimeError.new("#{who}: cannot serialize improper list") unless Creme.proper_list?(v)
        yaml.sequence do
          Creme.list_to_a(v).each { |e| yaml_write(e, yaml, who) }
        end
      end
    else
      raise SchemeRuntimeError.new("#{who}: cannot serialize #{v.write_string}")
    end
  end
end

module Creme
  class Interpreter
    register_library ["creme", "builtin", "yaml"], Creme::Builtins::YamlLibrary
  end
end
