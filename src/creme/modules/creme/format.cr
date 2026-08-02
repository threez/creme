# ===========================================================================
# format module: SRFI-28-style directive-based string formatting.
# (format #f fmt args...) returns a string; (format #t fmt args...) writes
# to current output — SRFI-28's exact destination-argument contract.
# ===========================================================================

module Creme::Builtins::FormatLibrary
  extend self
  include Creme::BuiltinHelpers

  @[Creme::SchemeFn("format", min: 2, max: -1)]
  def format(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    dest = args[0]
    fmt = format_arg(args[1], "format")
    rendered = format_render(fmt, args[2..-1], "format")
    case dest
    when SchemeBool
      if dest.value?
        interp.emit(rendered)
        NIL.as(SchemeValue)
      else
        SchemeStr.new(rendered).as(SchemeValue)
      end
    else
      raise SchemeRuntimeError.new("format: expected #t or #f as destination, got #{dest.write_string}")
    end
  end

  private def format_arg(v : SchemeValue, who : String) : String
    raise SchemeRuntimeError.new("#{who}: expected format string, got #{v.write_string}") unless v.is_a?(SchemeStr)
    v.value
  end

  private def format_render(fmt : String, args : Array(SchemeValue), who : String) : String
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

      raise SchemeRuntimeError.new("#{who}: dangling '~' at end of format string") if i + 1 >= chars.size
      directive = chars[i + 1]
      i += 2

      output, consumed_arg = format_directive(directive, args, idx, who)
      buf << output
      idx += 1 if consumed_arg
    end
    buf.to_s
  end

  private FORMAT_RADICES = {'d' => 10, 'x' => 16, 'o' => 8, 'b' => 2}

  private def format_directive(directive : Char, args : Array(SchemeValue), idx : Int32, who : String) : {String, Bool}
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
      raise SchemeRuntimeError.new("#{who}: ~c expected a char, got #{arg.write_string}") unless arg.is_a?(SchemeChar)
      {arg.value.to_s, true}
    else
      if radix = FORMAT_RADICES[directive.downcase]?
        {format_radix_arg(args, idx, who, radix), true}
      else
        raise SchemeRuntimeError.new("#{who}: unknown format directive '~#{directive}'")
      end
    end
  end

  private def format_next_arg(args : Array(SchemeValue), idx : Int32, who : String) : SchemeValue
    raise SchemeRuntimeError.new("#{who}: not enough arguments for format string") if idx >= args.size
    args[idx]
  end

  private def format_radix_arg(args : Array(SchemeValue), idx : Int32, who : String, radix : Int32) : String
    arg = format_next_arg(args, idx, who)
    raise SchemeRuntimeError.new("#{who}: expected integer, got #{arg.write_string}") unless arg.is_a?(SchemeInt)
    arg.value.to_s(radix)
  end
end

module Creme
  class Interpreter
    register_library ["creme", "builtin", "format"], Creme::Builtins::FormatLibrary
  end
end
