require "../../spec_helper"

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "defmacro" do
  it "expands a basic macro built with quasiquote" do
    w("(defmacro my-if (c t e) `(cond (,c ,t) (else ,e))) (my-if #t 1 2)").should eq("1")
    w("(defmacro my-if (c t e) `(cond (,c ,t) (else ,e))) (my-if #f 1 2)").should eq("2")
  end

  it "supports unquote-splicing for variadic bodies" do
    w("(defmacro my-begin (a . rest) `(begin ,a ,@rest)) (my-begin 1 2 3)").should eq("3")
  end

  it "raises the same arity-mismatch wording as lambda" do
    expect_raises(Scheme::SchemeRuntimeError, /expected 2 argument\(s\), got 1/) do
      run("(defmacro two-args (a b) a) (two-args 1)")
    end
  end

  it "supports a macro expanding to another macro" do
    src = <<-SCHEME
      (defmacro inner (x) `(+ ,x 1))
      (defmacro outer (x) `(inner ,x))
      (outer 5)
      SCHEME
    w(src).should eq("6")
  end

  describe "gensym-based capture avoidance" do
    it "returns a distinct symbol each call" do
      w("(import (creme introspection)) (eq? (gensym) (gensym))").should eq("#f")
    end

    it "returns a symbol" do
      w("(import (creme introspection)) (symbol? (gensym))").should eq("#t")
    end

    it "honors a prefix argument" do
      w(%((import (creme introspection)) (symbol->string (gensym "tmp")))).should match(/^"tmp__\d+"$/)
    end

    it "lets swap! avoid capturing the caller's own variable names" do
      src = <<-SCHEME
        (import (creme introspection))
        (defmacro swap! (a b)
          (let ((tmp (gensym)))
            `(let ((,tmp ,a)) (set! ,a ,b) (set! ,b ,tmp))))
        (define x 1)
        (define y 2)
        (swap! x y)
        (list x y)
        SCHEME
      w(src).should eq("(2 1)")
    end
  end

  it "raises when a macro is passed to the apply builtin" do
    expect_raises(Scheme::SchemeRuntimeError, /macro cannot be applied as a procedure: m/) do
      run("(defmacro m (x) x) (apply m (list 1))")
    end
  end

  it "raises when a macro is passed to map" do
    expect_raises(Scheme::SchemeRuntimeError, /macro cannot be applied as a procedure: m/) do
      run("(defmacro m (x) x) (map m (list 1 2))")
    end
  end

  describe "malformed input" do
    it "raises when the name is missing" do
      expect_raises(Scheme::SchemeRuntimeError, /defmacro: malformed/) { run("(defmacro)") }
    end

    it "raises when the name isn't a symbol" do
      expect_raises(Scheme::SchemeRuntimeError, /defmacro: macro name must be a symbol/) { run("(defmacro 1 (x) x)") }
    end

    it "raises when the formals list is missing" do
      expect_raises(Scheme::SchemeRuntimeError, /defmacro: malformed/) { run("(defmacro m)") }
    end

    it "raises when the body is empty" do
      expect_raises(Scheme::SchemeRuntimeError, /defmacro: macro body is empty/) { run("(defmacro m (x))") }
    end

    it "raises for a bad formal parameter" do
      expect_raises(Scheme::SchemeRuntimeError, /bad formal parameter/) { run("(defmacro m (1) 1)") }
    end
  end

  it "a macro named after a special form shadows it, like any other identifier (R7RS: syntactic keywords are lexically scoped bindings)" do
    w("(defmacro if (a) a) (if 42)").should eq("42")
    expect_raises(Scheme::SchemeRuntimeError, /if: expected 1 argument\(s\), got 3/) do
      run("(defmacro if (a) a) (if #t 1 2)")
    end
  end

  it "does not expand a macro call when merely quoted" do
    w("(defmacro some-macro (x) x) `(some-macro 1)").should eq("(some-macro 1)")
  end

  it "supports local, nested macro definitions scoped to their let" do
    w("(let () (defmacro m (x) x) (m 5))").should eq("5")
    expect_raises(Scheme::SchemeRuntimeError, /unbound variable: m/) do
      run("(let () (defmacro m (x) x) (m 5)) (m 5)")
    end
  end
end
