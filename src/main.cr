require "./lisp"

def repl(interp : LISP::Interpreter) : Nil
  buffer = ""
  loop do
    prompt = buffer.empty? ? "lisp> " : "  ... "
    print(prompt)
    line = STDIN.gets(chomp: false)
    if line.nil?
      puts
      break
    end
    buffer = buffer.empty? ? line : buffer + line
    next if buffer.strip.empty?

    begin
      forms = LISP::Reader.read_all(buffer)
      buffer = ""
      forms.each do |form|
        result = interp.eval(form, interp.global)
        puts result.write_string
      end
    rescue LISP::LispIncompleteError
      # keep buffer, request continuation
      next
    rescue ex : LISP::LispExit
      exit(ex.code)
    rescue ex : LISP::LispError
      buffer = ""
      puts "Error: #{ex.message}"
    rescue ex
      buffer = ""
      puts "Internal error: #{ex.message}"
    end
  end
end

def usage : Nil
  puts <<-USAGE
  crisp — a LISP interpreter (Crystal)

  Usage:
    crisp                 Start the interactive REPL
    crisp <file.lisp>     Execute a LISP source file
    crisp --help | -h     Show this help
  USAGE
end

def main : Nil
  args = ARGV
  if args.empty?
    interp = LISP::Interpreter.new
    if STDIN.tty?
      puts "crisp — Crystal LISP interpreter. Ctrl-D or (exit) to quit."
      repl(interp)
    else
      # read whole program from stdin
      src = STDIN.gets_to_end
      begin
        LISP::Reader.read_all(src).each { |form| interp.eval(form, interp.global) }
      rescue ex : LISP::LispExit
        exit(ex.code)
      rescue ex : LISP::LispError
        STDERR.puts "Error: #{ex.message}"
        exit 1
      rescue ex
        STDERR.puts "Internal error: #{ex.message}"
        exit 1
      end
    end
    return
  end

  case args[0]
  when "--help", "-h"
    usage
  else
    begin
      LISP.run_file(LISP::Interpreter.new, args[0])
    rescue ex : LISP::LispExit
      exit(ex.code)
    rescue ex : LISP::LispError
      STDERR.puts "Error: #{ex.message}"
      exit 1
    rescue ex
      STDERR.puts "Internal error: #{ex.message}"
      exit 1
    end
  end
end

main
