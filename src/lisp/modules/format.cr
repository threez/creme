# ===========================================================================
# format module: CHICKEN-style directive-based string formatting
# ===========================================================================

module LISP
  class Interpreter
    private def install_format(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(LispValue) -> LispValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      reg.call("sprintf", 1, -1, ->(args : Array(LispValue)) : LispValue do
        fmt = format_arg(args[0], "format:sprintf")
        LispStr.new(format_render(fmt, args[1..-1], "format:sprintf"))
      end)

      reg.call("printf", 1, -1, ->(args : Array(LispValue)) : LispValue do
        fmt = format_arg(args[0], "format:printf")
        emit(format_render(fmt, args[1..-1], "format:printf"))
        NIL.as(LispValue)
      end)

      reg.call("format", 2, -1, ->(args : Array(LispValue)) : LispValue do
        dest = args[0]
        fmt = format_arg(args[1], "format:format")
        rendered = format_render(fmt, args[2..-1], "format:format")
        case dest
        when LispBool
          if dest.value
            emit(rendered)
            NIL.as(LispValue)
          else
            LispStr.new(rendered).as(LispValue)
          end
        else
          raise LispRuntimeError.new("format:format: expected #t or #f as destination, got #{dest.write_string}")
        end
      end)
    end

    private def format_arg(v : LispValue, who : String) : String
      raise LispRuntimeError.new("#{who}: expected format string, got #{v.write_string}") unless v.is_a?(LispStr)
      v.value
    end

    private def format_render(fmt : String, args : Array(LispValue), who : String) : String
      buf = String::Builder.new
      idx = 0
      chars = fmt.chars
      i = 0
      while i < chars.size
        c = chars[i]
        unless c == '~'
          buf << c
          i += 1
          next
        end

        raise LispRuntimeError.new("#{who}: dangling '~' at end of format string") if i + 1 >= chars.size
        directive = chars[i + 1]
        i += 2

        output, consumed_arg = format_directive(directive, args, idx, who)
        buf << output
        idx += 1 if consumed_arg
      end
      buf.to_s
    end

    private FORMAT_RADICES = {'d' => 10, 'x' => 16, 'o' => 8, 'b' => 2}

    private def format_directive(directive : Char, args : Array(LispValue), idx : Int32, who : String) : {String, Bool}
      case directive.downcase
      when '~'
        {"~", false}
      when '%'
        {"\n", false}
      when 'a'
        {format_next_arg(args, idx, who).display_string, true}
      when 's'
        {format_next_arg(args, idx, who).write_string, true}
      when 'c'
        arg = format_next_arg(args, idx, who)
        raise LispRuntimeError.new("#{who}: ~c expected a char, got #{arg.write_string}") unless arg.is_a?(LispChar)
        {arg.value.to_s, true}
      else
        if (radix = FORMAT_RADICES[directive.downcase]?)
          {format_radix_arg(args, idx, who, radix), true}
        else
          raise LispRuntimeError.new("#{who}: unknown format directive '~#{directive}'")
        end
      end
    end

    private def format_next_arg(args : Array(LispValue), idx : Int32, who : String) : LispValue
      raise LispRuntimeError.new("#{who}: not enough arguments for format string") if idx >= args.size
      args[idx]
    end

    private def format_radix_arg(args : Array(LispValue), idx : Int32, who : String, radix : Int32) : String
      arg = format_next_arg(args, idx, who)
      raise LispRuntimeError.new("#{who}: expected integer, got #{arg.write_string}") unless arg.is_a?(LispInt)
      arg.value.to_s(radix)
    end
  end
end
