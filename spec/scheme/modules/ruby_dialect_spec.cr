require "../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (dialect ruby) (creme hash-table)) #{src}").write_string
end

describe "dialect ruby module" do
  it "to_s converts numbers, symbols, and strings" do
    w(%((to_s 42))).should eq(%("42"))
    w(%((to_s 'foo))).should eq(%("foo"))
    w(%((to_s "bar"))).should eq(%("bar"))
  end

  it "to_i parses a leading integer, defaulting to 0" do
    w(%((to_i "42abc"))).should eq("42")
    w(%((to_i "abc"))).should eq("0")
    w(%((to_i 3.7))).should eq("3")
  end

  it "to_f parses a leading decimal, defaulting to 0.0" do
    w(%((to_f "3.5xyz"))).should eq("3.5")
    w(%((to_f "abc"))).should eq("0.0")
  end

  it "puts prints each arg on its own line, flattening lists" do
    w(<<-SCHEME).should eq(%("1\\n2\\n3\\n"))
      (let ((p (open-output-string)))
        (parameterize ((current-output-port p))
          (puts '(1 2 3)))
        (get-output-string p))
      SCHEME
  end

  it "length/size dispatch across string, vector, hash-table, list" do
    w(%((length "hello"))).should eq("5")
    w(%((length #(1 2 3)))).should eq("3")
    w(%((length '(1 2 3 4)))).should eq("4")
  end

  it "each is receiver-first and dispatches across types" do
    w(<<-SCHEME).should eq("6")
      (define total 0)
      (each '(1 2 3) (lambda (x) (set! total (+ total x))))
      total
      SCHEME
  end

  it "each_with_index passes elem and index" do
    w(<<-SCHEME).should eq("((a . 0) (b . 1) (c . 2))")
      (define out '())
      (each_with_index '(a b c) (lambda (x i) (set! out (cons (cons x i) out))))
      (reverse out)
      SCHEME
  end

  it "keys/values read a hash-table" do
    w(<<-SCHEME).should eq("(2 1)")
      (define h (make-hash-table))
      (hash-table-set! h 'a 1)
      (hash-table-set! h 'b 2)
      (sort (values h) (lambda (a b) (> a b)))
      SCHEME
  end

  it "array helpers: push/pop/shift/unshift are pure" do
    w(%((push '(1 2) 3))).should eq("(1 2 3)")
    w(<<-SCHEME).should eq("(3 (1 2))")
      (call-with-values
        (lambda () (pop '(1 2 3)))
        (lambda (x rest) (list x rest)))
      SCHEME
  end

  it "sort defaults to < for numbers and string<? for strings" do
    w(%((sort '(3 1 2)))).should eq("(1 2 3)")
    w(%((sort '("b" "a" "c")))).should eq("(\"a\" \"b\" \"c\")")
  end

  it "do expands to a lambda, Ruby-block style" do
    w(<<-SCHEME).should eq("(0 1 2)")
      (define out '())
      (each_with_index '(a b c) (do (x i) (set! out (cons i out))))
      (reverse out)
      SCHEME
  end

  it "times calls proc with 0..n-1" do
    w(<<-SCHEME).should eq("(0 1 2)")
      (define out '())
      (times 3 (lambda (i) (set! out (cons i out))))
      (reverse out)
      SCHEME
  end

  it "times/upto/downto/step/each_with_index return void ('()), not #f" do
    w(%((times 3 (lambda (i) i)))).should eq("()")
    w(%((upto 1 3 (lambda (i) i)))).should eq("()")
    w(%((downto 3 1 (lambda (i) i)))).should eq("()")
    w(%((step 0 4 2 (lambda (i) i)))).should eq("()")
    w(%((each_with_index '(a b) (lambda (x i) x)))).should eq("()")
  end

  it "each/each_with_index/times/upto/downto/step accept bare do-sugar with no extra parens" do
    w(<<-SCHEME).should eq("6")
      (define total 0)
      (each '(1 2 3) do (x) (set! total (+ total x)))
      total
      SCHEME
    w(<<-SCHEME).should eq("(0 1 2)")
      (define out '())
      (each_with_index '(a b c) do (x i) (set! out (cons i out)))
      (reverse out)
      SCHEME
    w(<<-SCHEME).should eq("(0 1 2)")
      (define out '())
      (times 3 do (i) (set! out (cons i out)))
      (reverse out)
      SCHEME
    w(<<-SCHEME).should eq("(1 2 3)")
      (define out '())
      (upto 1 3 do (i) (set! out (cons i out)))
      (reverse out)
      SCHEME
    w(<<-SCHEME).should eq("(3 2 1)")
      (define out '())
      (downto 3 1 do (i) (set! out (cons i out)))
      (reverse out)
      SCHEME
    w(<<-SCHEME).should eq("(0 2 4)")
      (define out '())
      (step 0 4 2 do (i) (set! out (cons i out)))
      (reverse out)
      SCHEME
  end

  it "do-sugar with an empty param list ignores block args, Ruby-arity style" do
    w(<<-SCHEME).should eq(%("hellohellohello"))
      (let ((p (open-output-string)))
        (parameterize ((current-output-port p))
          (times 3 do () (display "hello")))
        (get-output-string p))
      SCHEME
  end

  it "each-proc/times-proc etc. remain plain, first-class procedures" do
    w(<<-SCHEME).should eq("6")
      (define total 0)
      (apply each-proc (list '(1 2 3) (lambda (x) (set! total (+ total x)))))
      total
      SCHEME
  end

  it "string helpers: upcase/strip/split/gsub" do
    w(%((upcase "hi"))).should eq(%("HI"))
    w(%((strip "  hi  "))).should eq(%("hi"))
    w(%((split "a,b,c" ","))).should eq(%(("a" "b" "c")))
    w(%((gsub "hello" "l" "L"))).should eq(%("heLLo"))
  end
end
