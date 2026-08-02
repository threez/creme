require "../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (scheme base) (creme tempfile) (creme file) (creme string)) #{src}").write_string
end

describe "tempfile module" do
  it "creates a file that actually exists on disk" do
    w(<<-SCHEME).should eq("#t")
      (define t (make-tempfile))
      (tempfile-close! t)
      (define existed (file-exists? (tempfile-path t)))
      (tempfile-unlink! t)
      existed
      SCHEME
  end

  it "names the file with the given prefix" do
    w(<<-SCHEME).should eq("#t")
      (define t (make-tempfile "myprefix"))
      (tempfile-close! t)
      (define has-prefix (string-contains? (tempfile-path t) "myprefix"))
      (tempfile-unlink! t)
      has-prefix
      SCHEME
  end

  it "writes to the open port and reads the content back" do
    w(<<-SCHEME).should eq(%("hello tempfile"))
      (define t (make-tempfile))
      (write-string "hello tempfile" (tempfile-port t))
      (tempfile-close! t)
      (define content (file-read (tempfile-path t)))
      (tempfile-unlink! t)
      content
      SCHEME
  end

  it "unlinks the file so it no longer exists" do
    w(<<-SCHEME).should eq("#f")
      (define t (make-tempfile))
      (tempfile-close! t)
      (tempfile-unlink! t)
      (file-exists? (tempfile-path t))
      SCHEME
  end

  it "unlink is a no-op if the file is already gone" do
    w(<<-SCHEME).should eq("#f")
      (define t (make-tempfile))
      (tempfile-close! t)
      (tempfile-unlink! t)
      (tempfile-unlink! t)
      (file-exists? (tempfile-path t))
      SCHEME
  end

  it "call-with-tempfile cleans up after a normal return" do
    w(<<-SCHEME).should eq("(#t #f)")
      (define seen-path #f)
      (define result
        (call-with-tempfile "cwt"
          (lambda (t)
            (write-string "data" (tempfile-port t))
            (tempfile-close! t)
            (set! seen-path (tempfile-path t))
            (file-exists? (tempfile-path t)))))
      (list result (file-exists? seen-path))
      SCHEME
  end

  it "call-with-tempfile cleans up even if proc raises" do
    w(<<-SCHEME).should eq("#f")
      (define seen-path #f)
      (guard (e (#t #f))
        (call-with-tempfile "cwt-err"
          (lambda (t)
            (set! seen-path (tempfile-path t))
            (error "boom"))))
      (file-exists? seen-path)
      SCHEME
  end

  it "recognizes tempfile? only for tempfile values" do
    w(<<-SCHEME).should eq("(#t #f)")
      (define t (make-tempfile))
      (define result (list (tempfile? t) (tempfile? 5)))
      (tempfile-close! t)
      (tempfile-unlink! t)
      result
      SCHEME
  end
end
