require "../../spec_helper"
require "file_utils"

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "R7RS §6.14 System interface" do
  it "load reads and evaluates a file's expressions/definitions against the current (or a given) environment" do
    dir = File.tempname("creme-r7rs-ch06-14-spec", "")
    Dir.mkdir_p(dir)
    begin
      File.write(File.join(dir, "triple.scm"), "(define (triple x) (* x 3))")
      interp = Creme::Interpreter.new(library_search_path: ["./modules"])
      interp.push_load_dir(dir)
      Creme.run_source(interp, <<-SCM).write_string.should eq("15")
        (import (scheme load))
        (load "triple.scm")
        (triple 5)
      SCM
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "(scheme file) provides file-exists?/delete-file/open-input-file/etc. under R7RS's own standard library name" do
    dir = File.tempname("creme-r7rs-ch06-14-spec", "")
    Dir.mkdir_p(dir)
    begin
      path = File.join(dir, "probe.txt")
      interp = Creme::Interpreter.new(library_search_path: ["./modules"])
      Creme.run_source(interp, <<-SCM).write_string.should eq("(#f #t #f)")
        (import (scheme file))
        (define path "#{path}")
        (define before (file-exists? path))
        (define op (open-output-file path))
        (close-port op)
        (define after-write (file-exists? path))
        (delete-file path)
        (list before after-write (file-exists? path))
      SCM
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "command-line returns the process's command line as a list of strings" do
    w("(import (scheme process-context)) (list? (command-line))").should eq("#t")
  end

  it "exit raises a catchable Creme::SchemeExit rather than terminating the host process, per this implementation's embedding contract" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    expect_raises(Creme::SchemeExit) do
      Creme.run_source(interp, "(import (scheme process-context)) (exit)")
    end
  end

  it "get-environment-variable returns #f for a name that is not set" do
    w(%[(import (scheme process-context)) (get-environment-variable "NONEXISTENT_VAR_XYZ")]).should eq("#f")
  end

  it "get-environment-variables returns an alist of all environment variable name/value pairs" do
    w("(import (scheme process-context)) (list? (get-environment-variables))").should eq("#t")
  end

  it "current-second returns an inexact number representing the current TAI time" do
    w("(import (scheme time)) (number? (current-second))").should eq("#t")
  end

  it "current-jiffy/jiffies-per-second provide an implementation-defined high-resolution clock" do
    w("(import (scheme time)) (list (number? (current-jiffy)) (number? (jiffies-per-second)))").should eq("(#t #t)")
  end
end
