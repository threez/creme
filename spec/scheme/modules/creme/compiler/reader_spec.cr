require "../../../../spec_helper"

private def load_reader(interp : Scheme::Interpreter) : Nil
  Scheme.run_source(interp, %((import (scheme write) (creme compiler reader))))
end

private def bootstrap_read(interp : Scheme::Interpreter, source : String) : String
  interp.global.define("bootstrap-test-source", Scheme::SchemeStr.new(source))
  result = Scheme.run_source(interp, <<-SCM)
  (let ((forms (read-program bootstrap-test-source))
        (out (open-output-string)))
    (for-each (lambda (f) (write f out) (write-char #\\newline out)) forms)
    (get-output-string out))
  SCM
  result.as(Scheme::SchemeStr).value
end

private def native_read(source : String) : String
  Scheme::Reader.read_all(source).map(&.write_string).join("\n") + "\n"
end

private def check(interp : Scheme::Interpreter, source : String) : Nil
  bootstrap_read(interp, source).should eq(native_read(source))
end

# `check` alone can't tell a genuine number from a same-spelled symbol
# apart (e.g. a wrongly-unclassified "1/2" token falling back to
# string->symbol would still `write` as "1/2", matching the real
# rational's own write form) -- this asserts the bootstrap reader's first
# datum is actually a number, not just that it prints like one.
private def check_number(interp : Scheme::Interpreter, source : String) : Nil
  check(interp, source)
  interp.global.define("bootstrap-test-source", Scheme::SchemeStr.new(source))
  Scheme.run_source(interp, "(number? (car (read-program bootstrap-test-source)))").write_string.should eq("#t")
end

describe "bootstrap-reader module" do
  it "reads atoms, lists, and structures matching the native reader" do
    interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
    load_reader(interp)
    [
      "()", "(1 2 3)", "(1 . 2)", "(1 2 . 3)", "(a (b c) . d)",
      "#(1 2 3)", "#()", "#u8(1 2 3 255)", "#u8()",
      "\"hello\\nworld\"", "\"tab\\tquote\\\"end\"", "\"\"", "\"a\\x41;b\"",
      "#\\a", "#\\space", "#\\newline", "#\\tab", "#\\x41", "#\\(", "#\\0",
      "#t", "#f", "#true", "#false",
      "'foo", "`(a ,b ,@c)", "(quote (a b))", "''x",
      "42", "-17", "3.14", "#x1A", "#b101", "#o17", "#e1.5", "#d42",
      "+inf.0", "-inf.0", "+nan.0",
      "sym-bol?", "+", "-", "...", "->foo", "list->vector", "a1b2",
      "|foo bar|", "|with \\| pipe|",
      "; comment\n42", "#| block |# 42", "#| nested #| deep |# still |# 42", "#;(ignored) 42",
      "[1 2 3]", "(a . [b])",
    ].each { |src| check(interp, src) }

    ["1/2", "-3/4", "1+2i", "1-2i", "-4i", "+i", "-i", "3+i", "1.5+2.5i"].each { |src| check_number(interp, src) }
  end

  it "reads a full mixed program" do
    interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
    load_reader(interp)
    src = <<-SCM
    (define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))
    ; a comment
    (define v #(1 2 3))
    (display (fact 5))
    SCM
    check(interp, src)
  end

  # Every real .scm/.sld file in the repo, read by both readers and
  # compared -- a much wider sweep than the hand-picked cases above.
  # competition/racket/bench/racket.scm is excluded: it's `#lang racket`,
  # not Scheme, and the NATIVE reader rejects it too.
  it "matches the native reader on every example/module source file in the repo" do
    interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
    load_reader(interp)
    files = (Dir.glob("examples/**/*.scm") + Dir.glob("modules/**/*.sld") + Dir.glob("competition/**/*.scm"))
      .reject(&.includes?("racket.scm"))
    files.size.should be > 0
    files.each { |path| check(interp, File.read(path)) }
  end
end
