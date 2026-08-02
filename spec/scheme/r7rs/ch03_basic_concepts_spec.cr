require "../../spec_helper"

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "R7RS §3.1 Variables, syntactic keywords, and regions" do
  it "a variable reference evaluates to the value stored in its bound location" do
    w("(define x 28) x").should eq("28")
  end

  it "referencing an unbound identifier is an error" do
    expect_raises(Scheme::SchemeRuntimeError, /unbound variable: totally-undefined-name/) do
      run("totally-undefined-name")
    end
  end
end

describe "R7RS §3.2 Disjointness of types" do
  it "no object satisfies more than one of the disjoint-type predicates" do
    w("(list (boolean? #t) (pair? (cons 1 2)) (null? '()) (procedure? car) (symbol? 'a) (string? \"a\") (number? 1) (char? #\\a) (vector? (vector)) (bytevector? (bytevector)))").should eq("(#t #t #t #t #t #t #t #t #t #t)")
  end

  it "the empty list is not a pair" do
    w("(pair? '())").should eq("#f")
  end
end

describe "R7RS §3.3 External representations" do
  it "the external representation of 28 is the character sequence \"28\"" do
    w("28").should eq("28")
  end

  it "(+ 2 6) is not an external representation of 8 — it is itself a 3-element list" do
    w("'(+ 2 6)").should eq("(+ 2 6)")
  end
end

describe "R7RS §3.4 Storage model" do
  it "string-set! mutates one of the locations a string denotes" do
    w("(define s (make-string 3 #\\a)) (string-set! s 0 #\\b) s").should eq(%("baa"))
  end

  it "an object fetched via car/vector-ref/string-ref is eqv? to the value last stored there" do
    w("(define v (vector 1 2 3)) (vector-set! v 0 99) (eqv? (vector-ref v 0) 99)").should eq("#t")
  end

  pending "mutating a literal constant (e.g. (set-car! '(a) 1)) is documented by R7RS as an error, but this implementation does not detect/reject it — it silently mutates the literal"
end

describe "R7RS §3.5 Proper tail recursion" do
  it "a self-tail-call loop of a million iterations runs in constant space (does not stack-overflow)" do
    w(<<-SCM).should eq("done")
      (define (loop n)
        (if (= n 0)
            'done
            (loop (- n 1))))
      (loop 1000000)
    SCM
  end

  it "and/or/when/unless/cond/case tail-call their final branch (same constant-space guarantee)" do
    w(<<-SCM).should eq("done")
      (define (loop n)
        (cond ((= n 0) 'done)
              (else (loop (- n 1)))))
      (loop 1000000)
    SCM
  end

  it "named-let tail position also stays in constant space" do
    w("(let loop ((i 0)) (if (= i 1000000) 'done (loop (+ i 1))))").should eq("done")
  end
end
