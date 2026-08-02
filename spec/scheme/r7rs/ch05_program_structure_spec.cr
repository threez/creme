require "../../spec_helper"
require "file_utils"

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "R7RS §5.1 Programs" do
  it "a program is a sequence of import declarations followed by expressions/definitions" do
    w("(import (scheme base)) (define x 1) (+ x 1)").should eq("2")
  end

  it "(begin ...) at the outermost level is equivalent to the sequence of its own contents" do
    w("(import (scheme base)) (begin (define x 1) (define y 2)) (+ x y)").should eq("3")
  end
end

describe "R7RS §5.2 Import declarations" do
  it "a bare (library name) import set imports everything the library exports" do
    w("(import (scheme base)) (+ 1 2)").should eq("3")
  end

  it "(only import-set identifier ...) imports just the listed identifiers" do
    w("(import (only (scheme base) +)) (+ 1 2)").should eq("3")
  end

  it "(except import-set identifier ...) imports everything except the listed identifiers" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"], auto_import_base: false)
    expect_raises(Creme::SchemeRuntimeError, /unbound variable: \+/) do
      Creme.run_source(interp, "(import (except (scheme base) +)) (+ 1 2)")
    end
  end

  it "(prefix import-set identifier) renames every imported identifier with the given prefix" do
    w("(import (prefix (scheme base) b:)) (b:+ 1 2)").should eq("3")
  end

  it "(rename import-set (id1 id2) ...) renames id1 to id2 in the imported bindings" do
    w("(import (rename (scheme base) (+ plus))) (plus 1 2)").should eq("3")
  end
end

describe "R7RS §5.3 Variable definitions" do
  it "(define variable expression) binds variable to the value of expression" do
    w("(import (scheme base)) (define add3 (lambda (x) (+ x 3))) (add3 3)").should eq("6")
  end

  it "(define (variable . formal) body) is sugar for (define variable (lambda formal body))" do
    w("(import (scheme base)) (define (f . args) args) (f 1 2 3)").should eq("(1 2 3)")
  end

  it "(define (variable formals) body) is sugar for (define variable (lambda (formals) body))" do
    w("(import (scheme base)) (define (first x) (car x)) (first '(1 2))").should eq("1")
  end

  it "define-values creates multiple definitions from a single multiple-value expression" do
    w("(import (scheme base)) (define-values (x y) (values 1 2)) (+ x y)").should eq("3")
  end

  it "internal definitions occur at the beginning of a body (lambda/let/letrec/etc.)" do
    w(<<-SCM).should eq("45")
      (import (scheme base))
      (let ((x 5))
        (define foo (lambda (y) (bar x y)))
        (define bar (lambda (a b) (+ (* a b) a)))
        (foo (+ x 3)))
    SCM
  end
end

describe "R7RS §5.4 Syntax definitions" do
  it "define-syntax at the outermost level extends the global syntactic environment" do
    w(<<-SCM).should eq("(2 1)")
      (import (scheme base))
      (define-syntax swap!
        (syntax-rules ()
          ((swap! a b) (let ((tmp a)) (set! a b) (set! b tmp)))))
      (define x 1)
      (define y 2)
      (swap! x y)
      (list x y)
    SCM
  end

  it "an internal syntax definition is local to the body it's defined in" do
    w(<<-SCM).should eq("7")
      (import (scheme base))
      (let ()
        (define-syntax double (syntax-rules () ((double e) (* 2 e))))
        (+ (double 3) 1))
    SCM
  end
end

describe "R7RS §5.5 Record-type definitions (define-record-type)" do
  it "defines a constructor, predicate, and field accessors/modifiers for a new record type" do
    w(<<-SCM).should eq("(#t #f 1 2 3)")
      (import (scheme base))
      (define-record-type <pare>
        (kons x y)
        pare?
        (x kar set-kar!)
        (y kdr))
      (define k (kons 1 2))
      (set-kar! k 3)
      (list (pare? k) (pare? (cons 1 2)) 1 2 (kar k))
    SCM
  end

  it "each define-record-type use creates a new, distinct record type even with the same field names" do
    w(<<-SCM).should eq("#f")
      (import (scheme base))
      (define-record-type point (make-point x y) point? (x point-x) (y point-y))
      (define-record-type point2 (make-point2 x y) point2? (x point2-x) (y point2-y))
      (point? (make-point2 1 2))
    SCM
  end
end

describe "R7RS §5.6 Libraries (define-library)" do
  it "a library exports only the identifiers listed in its export declaration" do
    w(<<-SCM).should eq("6")
      (define-library (test triple-lib)
        (export triple)
        (import (scheme base))
        (begin (define (triple x) (* x 3))))
      (import (test triple-lib))
      (triple 2)
    SCM
  end

  it "export supports (rename internal external) to expose a binding under a different external name" do
    w(<<-SCM).should eq("5")
      (define-library (test rename-lib)
        (export (rename internal-add public-add))
        (import (scheme base))
        (begin (define (internal-add a b) (+ a b))))
      (import (test rename-lib))
      (public-add 2 3)
    SCM
  end

  it "a library body sees only what it explicitly imports, not the importer's own bindings" do
    expect_raises(Creme::SchemeRuntimeError, /unbound variable: \+/) do
      run(<<-SCM)
        (define-library (test no-implicit-base)
          (export broken)
          (import)
          (begin (define (broken) (+ 1 2))))
        (import (test no-implicit-base))
        (broken)
      SCM
    end
  end

  it "include reads and evaluates a file's forms as if they appeared inline in a begin declaration" do
    dir = File.tempname("creme-r7rs-ch05-spec", "")
    Dir.mkdir_p(dir)
    begin
      File.write(File.join(dir, "triple.scm"), "(define (triple x) (* x 3))")
      interp = Creme::Interpreter.new(library_search_path: ["./modules"])
      interp.push_load_dir(dir)
      Creme.run_source(interp, <<-SCM).write_string.should eq("6")
        (define-library (test include-lib)
          (export triple)
          (import (scheme base))
          (include "triple.scm"))
        (import (test include-lib))
        (triple 2)
      SCM
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "include-ci reads a file as if it began with #!fold-case, lowercasing identifiers before lexing" do
    dir = File.tempname("creme-r7rs-ch05-spec", "")
    Dir.mkdir_p(dir)
    begin
      File.write(File.join(dir, "quad.scm"), "(DEFINE (QUADRUPLE X) (* X 4))")
      interp = Creme::Interpreter.new(library_search_path: ["./modules"])
      interp.push_load_dir(dir)
      Creme.run_source(interp, <<-SCM).write_string.should eq("8")
        (define-library (test include-ci-lib)
          (export quadruple)
          (import (scheme base))
          (include-ci "quad.scm"))
        (import (test include-ci-lib))
        (quadruple 2)
      SCM
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "cond-expand as a library declaration splices the matched clause's own declarations in place" do
    w(<<-SCM).should eq("yes")
      (define-library (test cond-expand-lib)
        (export foo)
        (import (scheme base))
        (cond-expand
          (r7rs (begin (define (foo) 'yes)))
          (else (begin (define (foo) 'no)))))
      (import (test cond-expand-lib))
      (foo)
    SCM
  end
end
