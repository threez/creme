require "../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (creme pstore) (creme tempfile) (creme file)) #{src}").write_string
end

describe "pstore module" do
  it "stores and retrieves a value within a transaction" do
    w(<<-SCHEME).should eq(%("bar"))
      (define t (make-tempfile "pstore"))
      (define path (tempfile-path t))
      (tempfile-close! t)
      (tempfile-unlink! t)
      (define store (pstore-open path))
      (pstore-transaction! store (lambda (s) (pstore-set! s 'foo "bar")))
      (pstore-ref store 'foo)
      SCHEME
  end

  it "persists across a fresh pstore-open of the same path" do
    w(<<-SCHEME).should eq(%("bar"))
      (define t (make-tempfile "pstore"))
      (define path (tempfile-path t))
      (tempfile-close! t)
      (tempfile-unlink! t)
      (pstore-transaction! (pstore-open path) (lambda (s) (pstore-set! s 'foo "bar")))
      (pstore-ref (pstore-open path) 'foo)
      SCHEME
  end

  it "returns #f for an unset key with no default" do
    w(<<-SCHEME).should eq("#f")
      (define t (make-tempfile "pstore"))
      (define path (tempfile-path t))
      (tempfile-close! t)
      (tempfile-unlink! t)
      (pstore-ref (pstore-open path) 'missing)
      SCHEME
  end

  it "returns the given default for an unset key" do
    w(<<-SCHEME).should eq("42")
      (define t (make-tempfile "pstore"))
      (define path (tempfile-path t))
      (tempfile-close! t)
      (tempfile-unlink! t)
      (pstore-ref (pstore-open path) 'missing 42)
      SCHEME
  end

  it "does not persist changes when the transaction aborts" do
    w(<<-SCHEME).should eq("(#f #f)")
      (define t (make-tempfile "pstore"))
      (define path (tempfile-path t))
      (tempfile-close! t)
      (tempfile-unlink! t)
      (define aborted-result
        (pstore-transaction! (pstore-open path)
          (lambda (s) (pstore-set! s 'foo "bar") (pstore-abort!) 'unreachable)))
      (list aborted-result (pstore-ref (pstore-open path) 'foo))
      SCHEME
  end

  it "does not persist changes when the transaction raises another error" do
    w(<<-SCHEME).should eq("#f")
      (define t (make-tempfile "pstore"))
      (define path (tempfile-path t))
      (tempfile-close! t)
      (tempfile-unlink! t)
      (guard (e (#t #f))
        (pstore-transaction! (pstore-open path)
          (lambda (s) (pstore-set! s 'foo "bar") (error "boom"))))
      (pstore-ref (pstore-open path) 'foo)
      SCHEME
  end

  it "deletes a key" do
    w(<<-SCHEME).should eq("(#t #f)")
      (define t (make-tempfile "pstore"))
      (define path (tempfile-path t))
      (tempfile-close! t)
      (tempfile-unlink! t)
      (define store (pstore-open path))
      (pstore-transaction! store (lambda (s) (pstore-set! s 'foo "bar")))
      (define had (pstore-root? store 'foo))
      (pstore-transaction! store (lambda (s) (pstore-delete! s 'foo)))
      (list had (pstore-root? store 'foo))
      SCHEME
  end

  it "lists roots" do
    w(<<-SCHEME).should eq("2")
      (define t (make-tempfile "pstore"))
      (define path (tempfile-path t))
      (tempfile-close! t)
      (tempfile-unlink! t)
      (define store (pstore-open path))
      (pstore-transaction! store (lambda (s) (pstore-set! s 'a 1) (pstore-set! s 'b 2)))
      (length (pstore-roots store))
      SCHEME
  end

  it "returns proc's own value from a successful transaction" do
    w(<<-SCHEME).should eq("99")
      (define t (make-tempfile "pstore"))
      (define path (tempfile-path t))
      (tempfile-close! t)
      (tempfile-unlink! t)
      (pstore-transaction! (pstore-open path) (lambda (s) 99))
      SCHEME
  end

  it "recognizes pstore? only for pstore values" do
    w(<<-SCHEME).should eq("(#t #f)")
      (define t (make-tempfile "pstore"))
      (define path (tempfile-path t))
      (tempfile-close! t)
      (tempfile-unlink! t)
      (list (pstore? (pstore-open path)) (pstore? 5))
      SCHEME
  end
end
