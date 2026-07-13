# ===========================================================================
# regex module: pattern matching on strings (SRFI-115 naming)
# ===========================================================================

module Scheme
  class SchemeRegex < SchemeValue
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
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(SchemeValue) -> SchemeValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      reg.call("regexp", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        pat = regex_str_arg(args[0], "regexp")
        begin
          SchemeRegex.new(Regex.new(pat), pat)
        rescue ex : Exception
          raise SchemeRuntimeError.new("regexp: invalid pattern '#{pat}': #{ex.message}")
        end
      end)

      reg.call("regexp-matches?", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        rx = regex_arg(args[0], "regexp-matches?")
        s = regex_str_arg(args[1], "regexp-matches?")
        SchemeBool.of(rx.matches?(s))
      end)

      reg.call("regexp-search", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        rx = regex_arg(args[0], "regexp-search")
        s = regex_str_arg(args[1], "regexp-search")
        if found = rx.match(s)
          Scheme.a_to_list(found.to_a.map { |group| group ? SchemeStr.new(group).as(SchemeValue) : FALSE.as(SchemeValue) })
        else
          FALSE.as(SchemeValue)
        end
      end)

      reg.call("regexp-extract", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        rx = regex_arg(args[0], "regexp-extract")
        s = regex_str_arg(args[1], "regexp-extract")
        matches = [] of SchemeValue
        s.scan(rx) do |found|
          matches << Scheme.a_to_list(found.to_a.map { |group| group ? SchemeStr.new(group).as(SchemeValue) : FALSE.as(SchemeValue) })
        end
        Scheme.a_to_list(matches)
      end)

      reg.call("regexp-replace", 3, 3, ->(args : Array(SchemeValue)) : SchemeValue do
        rx = regex_arg(args[0], "regexp-replace")
        rep = regex_str_arg(args[1], "regexp-replace")
        s = regex_str_arg(args[2], "regexp-replace")
        SchemeStr.new(s.sub(rx, rep))
      end)

      reg.call("regexp-replace-all", 3, 3, ->(args : Array(SchemeValue)) : SchemeValue do
        rx = regex_arg(args[0], "regexp-replace-all")
        rep = regex_str_arg(args[1], "regexp-replace-all")
        s = regex_str_arg(args[2], "regexp-replace-all")
        SchemeStr.new(s.gsub(rx, rep))
      end)

      reg.call("regexp-split", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        rx = regex_arg(args[0], "regexp-split")
        s = regex_str_arg(args[1], "regexp-split")
        Scheme.a_to_list(s.split(rx).map { |x| SchemeStr.new(x).as(SchemeValue) })
      end)

      reg.call("regexp?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        SchemeBool.of(args[0].is_a?(SchemeRegex))
      end)
    end

    private def regex_arg(v : SchemeValue, who : String) : Regex
      raise SchemeRuntimeError.new("#{who}: expected regex, got #{v.write_string}") unless v.is_a?(SchemeRegex)
      v.value
    end

    private def regex_str_arg(v : SchemeValue, who : String) : String
      raise SchemeRuntimeError.new("#{who}: expected string, got #{v.write_string}") unless v.is_a?(SchemeStr)
      v.value
    end
  end
end
