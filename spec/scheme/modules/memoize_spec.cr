require "../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme memoize)) #{src}").write_string
end

describe "memoize module" do
  it "returns the same result as the wrapped function" do
    w(%((let ((f (memoize (lambda (a b) (+ a b))))) (f 1 2)))).should eq("3")
  end

  it "only calls the wrapped function once per distinct argument list" do
    w(<<-SCHEME).should eq("2")
      (define calls 0)
      (define f (memoize (lambda (a b) (set! calls (+ calls 1)) (+ a b))))
      (f 1 2)
      (f 1 2)
      (f 1 2)
      (f 2 3)
      calls
      SCHEME
  end

  it "keys on the whole argument list, so different arguments are distinct entries" do
    w(%((let ((f (memoize (lambda (a b c) (list a b c))))) (list (f 1 #t "x") (f 1 #f "x") (f 2 #t "x")))))
      .should eq(%(((1 #t "x") (1 #f "x") (2 #t "x"))))
  end

  it "caches a #f result correctly, not treating it as a miss on the next call" do
    w(<<-SCHEME).should eq("(#f 1)")
      (define calls 0)
      (define f (memoize (lambda (x) (set! calls (+ calls 1)) #f)))
      (f 1)
      (list (f 1) calls)
      SCHEME
  end

  it "caches an empty-list result correctly" do
    w(<<-SCHEME).should eq("(() 1)")
      (define calls 0)
      (define f (memoize (lambda (x) (set! calls (+ calls 1)) '())))
      (f 1)
      (list (f 1) calls)
      SCHEME
  end

  describe "memoize-forget!" do
    it "forces a recompute on the next call with the forgotten argument list" do
      w(<<-SCHEME).should eq("2")
        (define calls 0)
        (define f (memoize (lambda (a b) (set! calls (+ calls 1)) (+ a b))))
        (f 1 2)
        (memoize-forget! f 1 2)
        (f 1 2)
        calls
        SCHEME
    end

    it "does not affect other cached argument lists" do
      w(<<-SCHEME).should eq("2")
        (define calls 0)
        (define f (memoize (lambda (a b) (set! calls (+ calls 1)) (+ a b))))
        (f 1 2)
        (f 3 4)
        (memoize-forget! f 1 2)
        (f 3 4)
        calls
        SCHEME
    end

    it "is a no-op when the argument list was never cached" do
      w(%((let ((f (memoize (lambda (x) x)))) (memoize-forget! f 99) "ok"))).should eq(%("ok"))
    end
  end

  describe "memoize-lru" do
    it "returns the same result as the wrapped function" do
      w(%((let ((f (memoize-lru (lambda (a b) (+ a b)) 2))) (f 1 2)))).should eq("3")
    end

    it "evicts the least-recently-used entry once max-size is exceeded" do
      w(<<-SCHEME).should eq("(2 3 2 1)")
        (define calls '())
        (define f (memoize-lru (lambda (x) (set! calls (cons x calls)) (* x 10)) 2))
        (f 1)
        (f 2)
        (f 1)
        (f 3)
        (f 2)
        calls
        SCHEME
    end

    it "a cache hit counts as a use, protecting a frequently-reused entry from eviction" do
      w(<<-SCHEME).should eq("(3 2 1)")
        (define calls '())
        (define f (memoize-lru (lambda (x) (set! calls (cons x calls)) (* x 10)) 2))
        (f 1)
        (f 2)
        (f 1)
        (f 3)
        (f 1)
        calls
        SCHEME
    end

    it "raises for a non-positive max-size" do
      expect_raises(Scheme::SchemeRuntimeError, /memoize-lru: max-size must be at least 1/) do
        Scheme.run_source(Scheme::Interpreter.new(library_search_path: ["./modules"]),
          "(import (creme memoize)) (memoize-lru (lambda (x) x) 0)")
      end
    end
  end
end
