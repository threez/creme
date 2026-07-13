# ===========================================================================
# string module: extended string operations (core unqualified builtins
# already provide string-append, string-length, substring, etc.)
# ===========================================================================

module Scheme
  class Interpreter
    private def install_string_ext(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(SchemeValue) -> SchemeValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      reg.call("string-upcase", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeStr.new(string_ext_arg(args[0], "string-upcase").upcase) })
      reg.call("string-downcase", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeStr.new(string_ext_arg(args[0], "string-downcase").downcase) })
      reg.call("string-trim", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeStr.new(string_ext_arg(args[0], "string-trim").strip) })
      reg.call("string-reverse", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeStr.new(string_ext_arg(args[0], "string-reverse").reverse) })

      reg.call("string-split", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        s = string_ext_arg(args[0], "string-split")
        sep = string_ext_arg(args[1], "string-split")
        Scheme.a_to_list(s.split(sep).map { |x| SchemeStr.new(x).as(SchemeValue) })
      end)

      reg.call("string-join", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        elems = Scheme.list_to_a(args[0])
        sep = string_ext_arg(args[1], "string-join")
        strs = elems.map do |e|
          raise SchemeRuntimeError.new("string-join: expected list of strings, got #{e.write_string}") unless e.is_a?(SchemeStr)
          e.value
        end
        SchemeStr.new(strs.join(sep))
      end)

      reg.call("string-replace", 3, 3, ->(args : Array(SchemeValue)) : SchemeValue do
        s = string_ext_arg(args[0], "string-replace")
        from = string_ext_arg(args[1], "string-replace")
        to = string_ext_arg(args[2], "string-replace")
        SchemeStr.new(s.gsub(from, to))
      end)

      reg.call("string-contains?", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        SchemeBool.of(string_ext_arg(args[0], "string-contains?").includes?(string_ext_arg(args[1], "string-contains?")))
      end)

      reg.call("string-prefix?", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        SchemeBool.of(string_ext_arg(args[0], "string-prefix?").starts_with?(string_ext_arg(args[1], "string-prefix?")))
      end)

      reg.call("string-suffix?", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        SchemeBool.of(string_ext_arg(args[0], "string-suffix?").ends_with?(string_ext_arg(args[1], "string-suffix?")))
      end)

      reg.call("string-index-of", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        s = string_ext_arg(args[0], "string-index-of")
        needle = string_ext_arg(args[1], "string-index-of")
        idx = s.index(needle)
        idx ? SchemeInt.new(idx.to_i64).as(SchemeValue) : FALSE.as(SchemeValue)
      end)

      reg.call("string-repeat", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        s = string_ext_arg(args[0], "string-repeat")
        n = args[1]
        raise SchemeRuntimeError.new("string-repeat: expected integer, got #{n.write_string}") unless n.is_a?(SchemeInt)
        raise SchemeRuntimeError.new("string-repeat: count must be non-negative") if n.value < 0
        SchemeStr.new(s * n.value)
      end)

      reg.call("string-pad", 3, 3, ->(args : Array(SchemeValue)) : SchemeValue do
        s = string_ext_arg(args[0], "string-pad")
        len = args[1]
        pad = string_ext_arg(args[2], "string-pad")
        raise SchemeRuntimeError.new("string-pad: expected integer, got #{len.write_string}") unless len.is_a?(SchemeInt)
        raise SchemeRuntimeError.new("string-pad: pad string must be exactly 1 char") unless pad.size == 1
        SchemeStr.new(s.rjust(len.value.to_i, pad[0]))
      end)

      reg.call("string-pad-right", 3, 3, ->(args : Array(SchemeValue)) : SchemeValue do
        s = string_ext_arg(args[0], "string-pad-right")
        len = args[1]
        pad = string_ext_arg(args[2], "string-pad-right")
        raise SchemeRuntimeError.new("string-pad-right: expected integer, got #{len.write_string}") unless len.is_a?(SchemeInt)
        raise SchemeRuntimeError.new("string-pad-right: pad string must be exactly 1 char") unless pad.size == 1
        SchemeStr.new(s.ljust(len.value.to_i, pad[0]))
      end)
    end

    private def string_ext_arg(v : SchemeValue, who : String) : String
      raise SchemeRuntimeError.new("#{who}: expected string, got #{v.write_string}") unless v.is_a?(SchemeStr)
      v.value
    end
  end
end
