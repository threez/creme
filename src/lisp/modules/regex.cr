# ===========================================================================
# regex module: pattern matching on strings
# ===========================================================================

module LISP
  class LispRegex < LispValue
    getter value : Regex
    getter source : String

    def initialize(@value : Regex, @source : String)
    end

    def to_display(io : IO) : Nil
      io << "#<regex:" << @source << '>'
    end
  end

  class Interpreter
    private def install_regex(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(LispValue) -> LispValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      reg.call("compile", 1, 1, ->(args : Array(LispValue)) : LispValue do
        pat = regex_str_arg(args[0], "regex:compile")
        begin
          LispRegex.new(Regex.new(pat), pat)
        rescue ex : Exception
          raise LispRuntimeError.new("regex:compile: invalid pattern '#{pat}': #{ex.message}")
        end
      end)

      reg.call("match?", 2, 2, ->(args : Array(LispValue)) : LispValue do
        rx = regex_arg(args[0], "regex:match?")
        s = regex_str_arg(args[1], "regex:match?")
        LispBool.of(rx.matches?(s))
      end)

      reg.call("match", 2, 2, ->(args : Array(LispValue)) : LispValue do
        rx = regex_arg(args[0], "regex:match")
        s = regex_str_arg(args[1], "regex:match")
        if found = rx.match(s)
          LISP.a_to_list(found.to_a.map { |group| group ? LispStr.new(group).as(LispValue) : FALSE.as(LispValue) })
        else
          FALSE.as(LispValue)
        end
      end)

      reg.call("find-all", 2, 2, ->(args : Array(LispValue)) : LispValue do
        rx = regex_arg(args[0], "regex:find-all")
        s = regex_str_arg(args[1], "regex:find-all")
        matches = [] of LispValue
        s.scan(rx) do |found|
          matches << LISP.a_to_list(found.to_a.map { |group| group ? LispStr.new(group).as(LispValue) : FALSE.as(LispValue) })
        end
        LISP.a_to_list(matches)
      end)

      reg.call("replace", 3, 3, ->(args : Array(LispValue)) : LispValue do
        rx = regex_arg(args[0], "regex:replace")
        rep = regex_str_arg(args[1], "regex:replace")
        s = regex_str_arg(args[2], "regex:replace")
        LispStr.new(s.sub(rx, rep))
      end)

      reg.call("replace-all", 3, 3, ->(args : Array(LispValue)) : LispValue do
        rx = regex_arg(args[0], "regex:replace-all")
        rep = regex_str_arg(args[1], "regex:replace-all")
        s = regex_str_arg(args[2], "regex:replace-all")
        LispStr.new(s.gsub(rx, rep))
      end)

      reg.call("split", 2, 2, ->(args : Array(LispValue)) : LispValue do
        rx = regex_arg(args[0], "regex:split")
        s = regex_str_arg(args[1], "regex:split")
        LISP.a_to_list(s.split(rx).map { |x| LispStr.new(x).as(LispValue) })
      end)

      reg.call("regex?", 1, 1, ->(args : Array(LispValue)) : LispValue do
        LispBool.of(args[0].is_a?(LispRegex))
      end)
    end

    private def regex_arg(v : LispValue, who : String) : Regex
      raise LispRuntimeError.new("#{who}: expected regex, got #{v.write_string}") unless v.is_a?(LispRegex)
      v.value
    end

    private def regex_str_arg(v : LispValue, who : String) : String
      raise LispRuntimeError.new("#{who}: expected string, got #{v.write_string}") unless v.is_a?(LispStr)
      v.value
    end
  end
end
