require "../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, "(import (creme file)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, "(import (creme file)) #{src}")
end

describe "file module" do
  it "writes, reads, checks existence, sizes, and deletes a file" do
    path = File.tempname("scheme_file_spec")
    begin
      w(%((file-write "#{path}" "hello"))).should eq("()")
      w(%((file-read "#{path}"))).should eq(%("hello"))
      w(%((file-exists? "#{path}"))).should eq("#t")
      w(%((file-size "#{path}"))).should eq("5")
      w(%((file-append "#{path}" " world"))).should eq("()")
      w(%((file-read "#{path}"))).should eq(%("hello world"))
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "reads lines" do
    path = File.tempname("scheme_file_spec_lines")
    File.write(path, "a\nb\nc\n")
    begin
      w(%((file-lines "#{path}"))).should eq(%(("a" "b" "c")))
    ensure
      File.delete(path)
    end
  end

  it "reports non-existence" do
    w(%((file-exists? "/no/such/path/scheme-spec"))).should eq("#f")
  end

  it "raises when reading a missing file" do
    expect_raises(Scheme::SchemeRuntimeError, /file-read: file not found/) do
      run(%((file-read "/no/such/path/scheme-spec")))
    end
  end

  it "a missing-file error satisfies file-error?, catchable via guard" do
    w(%[(guard (e ((file-error? e) 'is-file-error) (#t 'other)) (file-read "/no/such/path/scheme-spec"))]).should eq("is-file-error")
  end

  it "opens a port for writing, closes it, then reads it back via an input port" do
    path = File.tempname("scheme_file_spec_ports")
    begin
      w(%((let ((p (open-output-file "#{path}")))
             (write-string "line1" p)
             (write-char #\\newline p)
             (close-port p)
             (output-port? p)))).should eq("#t")
      w(%((let ((p (open-input-file "#{path}")))
             (let ((line (read-line p)))
               (close-port p)
               line)))).should eq(%("line1"))
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "reports eof-object at end of an input port" do
    path = File.tempname("scheme_file_spec_eof")
    File.write(path, "")
    begin
      w(%((let ((p (open-input-file "#{path}")))
             (let ((r (eof-object? (read-line p))))
               (close-port p)
               r)))).should eq("#t")
    ensure
      File.delete(path)
    end
  end

  it "call-with-output-file and call-with-input-file pass a port to the proc" do
    path = File.tempname("scheme_file_spec_call_with")
    begin
      w(%((call-with-output-file "#{path}" (lambda (p) (write-string "abc" p))))).should eq("()")
      w(%((call-with-input-file "#{path}" (lambda (p) (read-line p))))).should eq(%("abc"))
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "with-output-to-file and with-input-from-file redirect current ports" do
    path = File.tempname("scheme_file_spec_with")
    begin
      w(%((with-output-to-file "#{path}" (lambda () (display "redirected"))))).should eq("()")
      w(%((with-input-from-file "#{path}" (lambda () (read-line))))).should eq(%("redirected"))
    ensure
      File.delete(path) if File.exists?(path)
    end
  end
end
