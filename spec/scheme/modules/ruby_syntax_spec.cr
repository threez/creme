require "../../spec_helper"

# `#lang (creme syntax ruby)` runs the whole file as a script printing to
# real stdout, so these specs instead call (creme syntax ruby)'s own
# read-program directly and eval the resulting forms with stdout
# redirected to a string port -- the same approach (creme syntax slim)'s
# own spec uses for its no-export ("run standalone") mode.
private def run_ruby(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, <<-SCHEME).write_string
    (import (scheme base) (scheme write) (scheme eval) (creme syntax ruby))
    (let ((forms (cdr (read-program #{src.inspect} "t" (quote ()))))
          (env (environment '(scheme base) '(scheme write) '(dialect ruby)))
          (p (open-output-string)))
      (parameterize ((current-output-port p))
        (for-each (lambda (f) (eval f env)) forms))
      (get-output-string p))
    SCHEME
end

describe "(creme syntax ruby)" do
  it "def/end defines a callable method" do
    run_ruby(<<-RUBY).should eq(%("hi\\n"))
      def greet()
        puts "hi"
      end
      greet
      RUBY
  end

  it "if/else and string interpolation" do
    run_ruby(<<-RUBY).should eq(%("Hello, World!\\nHello, stranger\\n"))
      def greet(name)
        if name
          puts "Hello, \#{name}!"
        else
          puts "Hello, stranger"
        end
      end
      greet("World")
      greet(nil)
      RUBY
  end

  it "if/elsif/else picks the first true branch" do
    run_ruby(<<-RUBY).should eq(%("b\\n"))
      def classify(n)
        if n == 1
          puts "a"
        elsif n == 2
          puts "b"
        else
          puts "c"
        end
      end
      classify(2)
      RUBY
  end

  it "unless negates its condition" do
    run_ruby(<<-RUBY).should eq(%("not zero\\n"))
      def check(n)
        unless n == 0
          puts "not zero"
        end
      end
      check(5)
      RUBY
  end

  it "while loops until its condition is false" do
    run_ruby(<<-RUBY).should eq(%("0\\n1\\n2\\n"))
      i = 0
      while i < 3
        puts i
        i = i + 1
      end
      RUBY
  end

  it "array literals and dotted .each with a do/end block" do
    run_ruby(<<-RUBY).should eq(%("2\\n4\\n6\\n"))
      [1, 2, 3].each do |n|
        puts n * 2
      end
      RUBY
  end

  it "a no-paren call with an arithmetic argument" do
    run_ruby(<<-RUBY).should eq(%("6\\n"))
      n = 3
      puts n * 2
      RUBY
  end

  it "a dotted call with explicit-paren args" do
    run_ruby(<<-RUBY).should eq(%("5\\n"))
      puts "hello".length
      RUBY
  end

  it "symbol literals become quoted symbols" do
    run_ruby(<<-RUBY).should eq(%("foo\\n"))
      puts :foo
      RUBY
  end

  it "nil/false/true map onto Scheme's own #f/#t truthiness" do
    run_ruby(<<-RUBY).should eq(%("no\\n"))
      def check(v)
        if v
          puts "yes"
        else
          puts "no"
        end
      end
      check(nil)
      RUBY
    run_ruby(<<-RUBY).should eq(%("no\\n"))
      def check(v)
        if v
          puts "yes"
        else
          puts "no"
        end
      end
      check(false)
      RUBY
  end
end
