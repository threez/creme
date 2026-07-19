require "../../spec_helper"

# The register VM (BytecodeCompiler + VM, eval/vm.cr) is not wired into
# Scheme.run_source/run_file yet (see feature/bytecode-vm's phased plan) — it
# compiles/runs its own fresh Interpreter's forms directly, bypassing the
# tree-walker entirely, so these specs exercise it as its own independent
# evaluator. Uses BytecodeCompiler.run_program's per-form analyze-compile-run
# loop (mirroring Scheme.run_source), not a single upfront compile of every
# form — required for define-syntax/import to correctly affect later forms'
# analysis, exactly like the tree-walker's own per-form loop.
private def vm_run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new
  forms = Scheme::Reader.read_all(src)
  Scheme::BytecodeCompiler.run_program(interp, forms)
end

private def w(src : String) : String
  vm_run(src).write_string
end

describe "BytecodeCompiler + VM" do
  describe "literals, arithmetic, control flow" do
    it "evaluates arithmetic and comparisons" do
      w("(+ 1 2)").should eq("3")
      w("(* 6 7)").should eq("42")
      w("(< 1 2)").should eq("#t")
      w("(>= 2 3)").should eq("#f")
    end

    it "evaluates if/begin/and/or/when/unless" do
      w("(if (< 1 2) 'yes 'no)").should eq("yes")
      w("(begin 1 2 3)").should eq("3")
      w("(and 1 2 3)").should eq("3")
      w("(and 1 #f 3)").should eq("#f")
      w("(or #f #f 5)").should eq("5")
      w("(when (> 2 1) 'a 'b)").should eq("b")
      w("(unless (> 2 1) 'a 'b)").should eq("()")
    end

    it "evaluates let/let*/letrec" do
      w("(let ((a 1) (b 2)) (+ a b))").should eq("3")
      w("(let* ((a 1) (b (+ a 1))) (+ a b))").should eq("3")
      w("(letrec ((even? (lambda (n) (if (= n 0) #t (odd? (- n 1)))))" \
        "         (odd? (lambda (n) (if (= n 0) #f (even? (- n 1))))))" \
        "  (even? 10))").should eq("#t")
    end
  end

  describe "functions, recursion, tail calls" do
    it "computes non-tail recursion (fact)" do
      w("(define (fact n) (if (< n 2) 1 (* n (fact (- n 1))))) (fact 10)").should eq("3628800")
    end

    it "computes non-tail recursion (fib)" do
      w("(define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (fib 15)").should eq("610")
    end

    it "handles a large self-tail-recursive named-let loop without stack growth" do
      w("(let loop ((i 0) (acc 0)) (if (= i 1000000) acc (loop (+ i 1) (+ acc i))))")
        .should eq("499999500000")
    end

    it "handles rest args" do
      w("(define (f . xs) xs) (f 1 2 3)").should eq("(1 2 3)")
      w("(define (f a . rest) (list a rest)) (f 1 2 3)").should eq("(1 (2 3))")
    end
  end

  describe "closures and upvalues" do
    it "mutates a shared upvalue across calls" do
      w("(define (make-counter) (let ((n 0)) (lambda () (set! n (+ n 1)) n)))" \
        "(define c (make-counter)) (c) (c) (c)").should eq("3")
    end

    it "captures each loop iteration's own value independently (not aliased)" do
      w("(define (make-adders n)" \
        "  (let loop ((i 0) (acc '()))" \
        "    (if (= i n) acc (loop (+ i 1) (cons (lambda (x) (+ x i)) acc)))))" \
        "(define adders (make-adders 3))" \
        "(map (lambda (f) (f 100)) adders)").should eq("(102 101 100)")
    end
  end

  describe "vectors, strings, bytevectors (fused prim ops)" do
    it "vector-ref/vector-set!/vector-length" do
      w("(define v (vector 1 2 3)) (vector-set! v 1 99) (vector-ref v 1)").should eq("99")
      w("(vector-length (vector 1 2 3))").should eq("3")
    end

    it "string-ref/string-set!" do
      w("(let ((s (make-string 3 #\\a))) (string-set! s 1 #\\z) s)").should eq("\"aza\"")
    end

    it "bytevector-u8-ref/bytevector-u8-set!" do
      w("(let ((b (make-bytevector 2))) (bytevector-u8-set! b 0 42) (bytevector-u8-ref b 0))").should eq("42")
    end
  end

  describe "cons/not/null?/pair?/eq? (fused prim ops)" do
    it "computes correctly" do
      w("(cons 1 2)").should eq("(1 . 2)")
      w("(not #f)").should eq("#t")
      w("(not 5)").should eq("#f")
      w("(null? '())").should eq("#t")
      w("(null? 5)").should eq("#f")
      w("(pair? (cons 1 2))").should eq("#t")
      w("(pair? '())").should eq("#f")
      w("(eq? 'x 'x)").should eq("#t")
      w("(eq? 'x 'y)").should eq("#f")
    end
  end

  describe "cond" do
    it "picks the first matching clause, supports else/=>/empty-body" do
      w("(cond ((= 1 2) 'a) ((= 1 1) 'b) (else 'c))").should eq("b")
      w("(cond (#f 'a) (else 'c))").should eq("c")
      w("(cond ((assv 1 '((1 . one) (2 . two))) => cdr) (else 'none))").should eq("one")
      w("(cond (#f 'a))").should eq("()")
      w("(cond (42))").should eq("42") # bare test value, no body
    end
  end

  describe "case" do
    it "matches via eqv?, supports else/=>/empty-body" do
      w("(case (* 2 3) ((2 3 5 7) 'prime) ((1 4 6 8 9) 'composite) (else 'unknown))").should eq("composite")
      w("(case (car '(c d)) ((a e i o u) 'vowel) ((w y) 'semivowel)" \
        "  (else => (lambda (x) (list 'other x))))").should eq("(other c)")
      w("(case 99 ((1 2) 'a))").should eq("()") # no match, no else -> NIL
      w("(case 1 ((1) ))").should eq("()")      # bare-datum match, empty body -> NIL (not the key)
    end

    # 8+ total datums, all hashable (ints here) -- exercises
    # BytecodeCompiler#compile_case_hash_dispatch/Op::CaseDispatch instead of
    # the linear CaseMatch/TestFalse chain (see hashable_case?'s threshold).
    it "hash-dispatches large all-literal case forms (Op::CaseDispatch)" do
      big = <<-SCM
        (case n
          ((0 1) 'zero-or-one)
          ((2 3) 'two-or-three)
          ((4 5) 'four-or-five)
          ((6 7) 'six-or-seven)
          (else 'other))
      SCM
      w("(define n 0) #{big}").should eq("zero-or-one")  # match on first clause
      w("(define n 7) #{big}").should eq("six-or-seven") # match on last clause
      w("(define n 42) #{big}").should eq("other")       # no match, has else

      no_else = <<-SCM
        (case n
          ((0 1) 'a) ((2 3) 'b) ((4 5) 'c) ((6 7) 'd))
      SCM
      w("(define n 42) #{no_else}").should eq("()") # no match, no else -> NIL
    end

    it "hash-dispatch: first clause wins on a duplicate datum across clauses" do
      w(<<-SCM
        (case 1
          ((1 2) 'first) ((1 3) 'second) ((4 5) 'x) ((6 7) 'y) (else 'z))
        SCM
      ).should eq("first")
    end

    it "hash-dispatch: distinguishes datum types that could otherwise collide" do
      w(<<-SCM
        (case #\\a
          ((0 1) 'int-zero-or-one)
          ((#\\a #\\b) 'char-a-or-b)
          ((foo bar) 'sym)
          ((#t #f) 'bool)
          (else 'none))
        SCM
      ).should eq("char-a-or-b")
      w(<<-SCM
        (case #f
          ((0 1) 'int-zero-or-one)
          ((#\\a #\\b) 'char-a-or-b)
          ((foo bar) 'sym)
          ((#t #f) 'bool)
          (else 'none))
        SCM
      ).should eq("bool")
    end

    it "falls back to the linear path when else isn't last" do
      w(<<-SCM
        (case 9
          ((0 1) 'a) (else 'else-first) ((2 3) 'b) ((4 5) 'c) ((6 7) 'd))
        SCM
      ).should eq("else-first")
    end

    it "falls back to the linear path for non-hashable datum types" do
      w(<<-SCM
        (case 1.5
          ((0 1) 'a) ((2 3) 'b) ((1.5 2.5) 'floats) ((4 5) 'c) (else 'z))
        SCM
      ).should eq("floats")
    end

    it "falls back to the linear path for a malformed clause" do
      expect_raises(Scheme::SchemeRuntimeError, /empty clause/) do
        vm_run(<<-SCM
          (case 99
            ((0 1) 'a) ((2 3) 'b) ((4 5) 'c) ((6 7) 'd) ())
          SCM
        )
      end
    end
  end

  describe "case-lambda" do
    it "dispatches by argument count, including a rest clause" do
      w("(define f (case-lambda" \
        "            (() 'zero)" \
        "            ((a) (list 'one a))" \
        "            ((a b) (list 'two a b))" \
        "            ((a . rest) (list 'many a rest))))" \
        "(list (f) (f 1) (f 1 2) (f 1 2 3 4))")
        .should eq("(zero (one 1) (two 1 2) (many 1 (2 3 4)))")
    end
  end

  describe "multiple values" do
    it "define-values, including a rest binding" do
      w("(define-values (q r) (values 3 4)) (list q r)").should eq("(3 4)")
      w("(define-values (a . rest) (values 1 2 3)) (list a rest)").should eq("(1 (2 3))")
    end

    it "let-values (non-sequential) and let*-values (sequential)" do
      w("(let-values (((a b) (values 1 2)) ((c) (values 3))) (list a b c))").should eq("(1 2 3)")
      w("(let*-values (((a b) (values 1 2)) ((c) (values (+ a b)))) (list a b c))").should eq("(1 2 3)")
    end

    it "call-with-values bridges through Interpreter#apply correctly" do
      w("(call-with-values (lambda () (values 1 2)) (lambda (a b) (+ a b)))").should eq("3")
    end
  end

  describe "parameterize" do
    it "restores the saved value after the body, including nested and converter cases" do
      w("(define p (make-parameter 10)) (list (p) (parameterize ((p 20)) (p)) (p))")
        .should eq("(10 20 10)")
      w("(define p (make-parameter 5 (lambda (v) (* v 2))))" \
        "(list (p) (parameterize ((p 3)) (p)) (p))").should eq("(10 6 10)")
      w("(define p (make-parameter 1)) (define (f) (p))" \
        "(parameterize ((p 99)) (list (f) (parameterize ((p 100)) (f)) (f)))").should eq("(99 100 99)")
    end
  end

  describe "guard" do
    it "catches an error and runs the matching clause" do
      w("(guard (e (#t (list 'caught (error-object? e) (error-object-message e))))" \
        "  (error \"boom\" 1 2))").should eq("(caught #t \"boom\")")
      w("(guard (e ((symbol? e) (list 'sym e)) (#t (list 'other e))) (raise 'oops))")
        .should eq("(sym oops)")
    end

    it "catches an error raised from a non-tail call deep inside the body" do
      w("(define (f n) (guard (e (#t (list 'caught n)))" \
        "  (if (= n 0) (error \"boom\") 'ok)))" \
        "(list (f 1) (f 0))").should eq("(ok (caught 0))")
    end

    it "re-raises to an outer guard when no clause matches" do
      w("(guard (e1 (#t (list 'outer e1)))" \
        "  (guard (e2 ((string? e2) (list 'inner-string e2))) (raise 'not-a-string)))")
        .should eq("(outer not-a-string)")
    end

    it "unwinds cleanly through several levels of non-tail recursion" do
      w("(define log '())" \
        "(define (rec n)" \
        "  (guard (e (#t (set! log (cons 'caught log)) 'handled))" \
        "    (if (= n 0) (error \"deep\")" \
        "        (begin (set! log (cons n log)) (rec (- n 1))))))" \
        "(rec 5) (reverse log)").should eq("(5 4 3 2 1 caught)")
    end

    it "can appear as an ordinary operand mid-expression" do
      w("(+ 1 (guard (e (#t 100)) (car 5)))").should eq("101")
    end
  end

  describe "dynamic-wind, call/cc, with-exception-handler (already plain Builtins — no VM-specific code needed)" do
    it "runs before/thunk/after in order" do
      w("(define log '())" \
        "(dynamic-wind" \
        "  (lambda () (set! log (cons 'before log)))" \
        "  (lambda () (set! log (cons 'during log)))" \
        "  (lambda () (set! log (cons 'after log))))" \
        "(reverse log)").should eq("(before during after)")
    end

    it "still runs after when thunk errors, caught by an outer guard" do
      w("(define log '())" \
        "(guard (e (#t 'caught))" \
        "  (dynamic-wind" \
        "    (lambda () (set! log (cons 'before log)))" \
        "    (lambda () (error \"fail\"))" \
        "    (lambda () (set! log (cons 'after log)))))" \
        "(reverse log)").should eq("(before after)")
    end

    it "call/cc escapes immediately, discarding the rest of its own call site" do
      w("(+ 1 (call/cc (lambda (k) (+ 2 (k 10)))))").should eq("11")
    end

    it "call/cc escapes a for-each loop early" do
      w("(call/cc (lambda (return)" \
        "  (for-each (lambda (x) (if (= x 3) (return x))) '(1 2 3 4 5))" \
        "  'not-found))").should eq("3")
    end

    it "escaping a dynamic-wind's thunk via a captured continuation still runs after" do
      w("(define log '())" \
        "(call/cc (lambda (k)" \
        "  (dynamic-wind" \
        "    (lambda () (set! log (cons 'in log)))" \
        "    (lambda () (k 'escaped))" \
        "    (lambda () (set! log (cons 'out log))))))" \
        "(reverse log)").should eq("(in out)")
    end

    it "raise-continuable calls the handler in-line and uses its return value" do
      w("(with-exception-handler" \
        "  (lambda (e) 1000)" \
        "  (lambda () (+ 1 (raise-continuable 'oops))))").should eq("1001")
    end
  end

  describe "quasiquote" do
    it "evaluates unquote, unquote-splicing, vectors, and nested quasiquote" do
      w("(define x 5) `(a b ,x ,(+ x 1))").should eq("(a b 5 6)")
      w("(define lst '(2 3 4)) `(1 ,@lst 5)").should eq("(1 2 3 4 5)")
      w("`#(1 ,(+ 1 1) 3)").should eq("#(1 2 3)")
      w("``(a ,(b ,(+ 1 2)))").should eq("(quasiquote (a (unquote (b 3))))")
    end
  end

  describe "delay/force" do
    it "memoizes — the thunk runs only once across repeated force calls" do
      w("(import (scheme lazy))" \
        "(define count 0)" \
        "(define p (delay (begin (set! count (+ count 1)) count)))" \
        "(list (force p) (force p) count)").should eq("(1 1 1)")
    end
  end

  describe "define-record-type" do
    it "builds a constructor, predicate, accessors, and mutator" do
      w("(define-record-type point" \
        "  (make-point x y)" \
        "  point?" \
        "  (x point-x set-point-x!)" \
        "  (y point-y set-point-y!))" \
        "(define p (make-point 3 4))" \
        "(set-point-x! p 10)" \
        "(list (point? p) (point-x p) (point-y p) (point? 5))").should eq("(#t 10 4 #f)")
    end
  end

  describe "define-syntax / defmacro" do
    it "expands syntax-rules macros, including ones affecting LATER top-level forms" do
      w("(define-syntax my-if (syntax-rules () ((_ c t e) (cond (c t) (else e)))))" \
        "(my-if #t 'yes 'no)").should eq("yes")
      w("(define-syntax swap! (syntax-rules () ((_ a b) (let ((tmp a)) (set! a b) (set! b tmp)))))" \
        "(define x 1) (define y 2) (swap! x y) (list x y)").should eq("(2 1)")
    end
  end

  describe "do" do
    it "builds a vector via mutation across iterations" do
      w("(do ((vec (make-vector 5)) (i 0 (+ i 1))) ((= i 5) vec) (vector-set! vec i i))")
        .should eq("#(0 1 2 3 4)")
    end

    it "supports a self-tail-recursive accumulation with no explicit step for some vars" do
      w("(do ((x 1 (* x 2)) (i 0 (+ i 1))) ((= i 20) x))").should eq("1048576")
    end

    it "returns unspecified with no result forms" do
      w("(do ((i 0 (+ i 1))) ((= i 3)))").should eq("()")
    end
  end
end
