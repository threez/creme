require "../../spec_helper"

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "(creme ...) namespace" do
  it "none of the 17 custom libraries are auto-imported" do
    # Literal args (not nested (string->bigdecimal ...) calls) so this is
    # insensitive to operator-vs-operand evaluation order (R7RS §4.1.3
    # leaves it unspecified; a bare-name callee is resolved after its args
    # are evaluated) — the point is only that the (creme bigdecimal) name
    # itself isn't in scope without an explicit import.
    expect_raises(Scheme::SchemeRuntimeError, /unbound variable: bigdecimal-add/) do
      run(%[(bigdecimal-add 1 2)])
    end
  end

  it "(creme bigdecimal) provides exact decimal arithmetic" do
    w(%[(import (creme bigdecimal)) (bigdecimal->string (bigdecimal-add (string->bigdecimal "1.5") (string->bigdecimal "2.25")))]).should eq(%("3.75"))
  end

  it "(creme math) is a superset of (scheme inexact), including log2/log10/atan2/pow/hypot/pi/e" do
    w("(import (creme math)) (sin 0)").should eq("0.0")
    w("(import (creme math)) (pow 2 10)").should eq("1024.0")
    w("(import (creme math) (scheme base)) (> pi 3)").should eq("#t")
  end

  it "(creme regex) provides pattern matching" do
    w(%[(import (creme regex)) (regexp-matches? (regexp "^[0-9]+$") "123")]).should eq("#t")
  end

  it "(creme json) provides json-read/json-write" do
    w(%[(import (creme json)) (json-write '(("a" . 1)))]).should eq(%("{\\"a\\":1}"))
  end

  it "(creme time) is a superset of the old rich epoch/format time API, distinct from (scheme time)" do
    w("(import (creme time)) (> (current-time) 0)").should eq("#t")
    w("(import (creme time)) (time-year (current-time))").should_not be_nil
  end

  it "(creme string) provides extended string operations" do
    w(%[(import (creme string)) (string-reverse "abc")]).should eq(%("cba"))
  end

  it "(creme format) provides format" do
    w(%[(import (creme format)) (format #f "~a-~a" 1 2)]).should eq(%("1-2"))
  end

  it "(creme random) provides random-real/random-integer/etc" do
    w("(import (creme random)) (< (random-real) 1.0)").should eq("#t")
  end

  it "(creme digest) provides hashing/base64" do
    w(%[(import (creme digest)) (base64-encode "hi")]).should eq(%("aGk="))
  end

  it "(creme env) provides get-environment-variable(s)" do
    w("(import (creme env)) (list? (get-environment-variables))").should eq("#t")
  end

  it "(creme process) provides process-run/command-line" do
    w("(import (creme process)) (list? (command-line))").should eq("#t")
  end

  it "(creme sql) provides sqlite access" do
    w("(import (creme sql)) (sql-connection? (sql-open \":memory:\"))").should eq("#t")
  end

  it "(creme hash-table) provides mutable hash tables" do
    w("(import (creme hash-table)) (define h (make-hash-table)) (hash-table-set! h 'a 1) (hash-table-ref h 'a)").should eq("1")
  end

  it "(creme rfc8439) provides ChaCha20/Poly1305" do
    w("(import (creme rfc8439)) (bytevector? (rfc8439-random-key))").should eq("#t")
  end
end
