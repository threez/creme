# ===========================================================================
# string module: extended string operations (core unqualified builtins
# already provide string-append, string-length, substring, etc.)
# ===========================================================================

module LISP
  class Interpreter
    private def install_string_ext(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(LispValue) -> LispValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      reg.call("upcase", 1, 1, ->(args : Array(LispValue)) : LispValue { LispStr.new(string_ext_arg(args[0], "string:upcase").upcase) })
      reg.call("downcase", 1, 1, ->(args : Array(LispValue)) : LispValue { LispStr.new(string_ext_arg(args[0], "string:downcase").downcase) })
      reg.call("trim", 1, 1, ->(args : Array(LispValue)) : LispValue { LispStr.new(string_ext_arg(args[0], "string:trim").strip) })
      reg.call("reverse", 1, 1, ->(args : Array(LispValue)) : LispValue { LispStr.new(string_ext_arg(args[0], "string:reverse").reverse) })

      reg.call("split", 2, 2, ->(args : Array(LispValue)) : LispValue do
        s = string_ext_arg(args[0], "string:split")
        sep = string_ext_arg(args[1], "string:split")
        LISP.a_to_list(s.split(sep).map { |x| LispStr.new(x).as(LispValue) })
      end)

      reg.call("join", 2, 2, ->(args : Array(LispValue)) : LispValue do
        elems = LISP.list_to_a(args[0])
        sep = string_ext_arg(args[1], "string:join")
        strs = elems.map do |e|
          raise LispRuntimeError.new("string:join: expected list of strings, got #{e.write_string}") unless e.is_a?(LispStr)
          e.value
        end
        LispStr.new(strs.join(sep))
      end)

      reg.call("replace", 3, 3, ->(args : Array(LispValue)) : LispValue do
        s = string_ext_arg(args[0], "string:replace")
        from = string_ext_arg(args[1], "string:replace")
        to = string_ext_arg(args[2], "string:replace")
        LispStr.new(s.gsub(from, to))
      end)

      reg.call("contains?", 2, 2, ->(args : Array(LispValue)) : LispValue do
        LispBool.of(string_ext_arg(args[0], "string:contains?").includes?(string_ext_arg(args[1], "string:contains?")))
      end)

      reg.call("starts-with?", 2, 2, ->(args : Array(LispValue)) : LispValue do
        LispBool.of(string_ext_arg(args[0], "string:starts-with?").starts_with?(string_ext_arg(args[1], "string:starts-with?")))
      end)

      reg.call("ends-with?", 2, 2, ->(args : Array(LispValue)) : LispValue do
        LispBool.of(string_ext_arg(args[0], "string:ends-with?").ends_with?(string_ext_arg(args[1], "string:ends-with?")))
      end)

      reg.call("index-of", 2, 2, ->(args : Array(LispValue)) : LispValue do
        s = string_ext_arg(args[0], "string:index-of")
        needle = string_ext_arg(args[1], "string:index-of")
        idx = s.index(needle)
        idx ? LispInt.new(idx.to_i64).as(LispValue) : FALSE.as(LispValue)
      end)

      reg.call("chars", 1, 1, ->(args : Array(LispValue)) : LispValue do
        s = string_ext_arg(args[0], "string:chars")
        LISP.a_to_list(s.chars.map { |chr| LispChar.new(chr).as(LispValue) })
      end)

      reg.call("repeat", 2, 2, ->(args : Array(LispValue)) : LispValue do
        s = string_ext_arg(args[0], "string:repeat")
        n = args[1]
        raise LispRuntimeError.new("string:repeat: expected integer, got #{n.write_string}") unless n.is_a?(LispInt)
        raise LispRuntimeError.new("string:repeat: count must be non-negative") if n.value < 0
        LispStr.new(s * n.value)
      end)

      reg.call("pad-left", 3, 3, ->(args : Array(LispValue)) : LispValue do
        s = string_ext_arg(args[0], "string:pad-left")
        len = args[1]
        pad = string_ext_arg(args[2], "string:pad-left")
        raise LispRuntimeError.new("string:pad-left: expected integer, got #{len.write_string}") unless len.is_a?(LispInt)
        raise LispRuntimeError.new("string:pad-left: pad string must be exactly 1 char") unless pad.size == 1
        LispStr.new(s.rjust(len.value.to_i, pad[0]))
      end)

      reg.call("pad-right", 3, 3, ->(args : Array(LispValue)) : LispValue do
        s = string_ext_arg(args[0], "string:pad-right")
        len = args[1]
        pad = string_ext_arg(args[2], "string:pad-right")
        raise LispRuntimeError.new("string:pad-right: expected integer, got #{len.write_string}") unless len.is_a?(LispInt)
        raise LispRuntimeError.new("string:pad-right: pad string must be exactly 1 char") unless pad.size == 1
        LispStr.new(s.ljust(len.value.to_i, pad[0]))
      end)
    end

    private def string_ext_arg(v : LispValue, who : String) : String
      raise LispRuntimeError.new("#{who}: expected string, got #{v.write_string}") unless v.is_a?(LispStr)
      v.value
    end
  end
end
