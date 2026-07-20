require "./spec_helper"

private BIN_PATH = File.join(Dir.current, "bin", "creme_spec")

Spec.before_suite do
  build = Process.run("crystal", ["build", "src/main.cr", "-o", BIN_PATH])
  raise "failed to build creme for main_spec" unless build.success?
end

private def run_cli(args : Array(String) = [] of String, stdin : String = "") : {String, String, Process::Status}
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(BIN_PATH, args, input: IO::Memory.new(stdin), output: output, error: error)
  {output.to_s, error.to_s, status}
end

describe "main.cr (CLI)" do
  it "reads a program from stdin (non-tty) and evaluates it" do
    out, err, status = run_cli(stdin: "(import (scheme base) (scheme write)) (display (+ 1 2)) (newline)")
    status.success?.should be_true
    out.should eq("3\n")
    err.should eq("")
  end

  it "runs a file argument and exits 0" do
    file = File.tempfile("main_spec", ".scm") do |io|
      io.print(%((import (scheme base) (scheme write)) (display "hello from file") (newline)))
    end
    begin
      out, err, status = run_cli([file.path])
      status.success?.should be_true
      out.should eq("hello from file\n")
      err.should eq("")
    ensure
      File.delete(file.path)
    end
  end

  it "prints usage for --help" do
    out, _, status = run_cli(["--help"])
    status.success?.should be_true
    out.should contain("creme — a Scheme interpreter (Crystal)")
  end

  it "prints usage for -h" do
    out, _, status = run_cli(["-h"])
    status.success?.should be_true
    out.should contain("Usage:")
  end

  it "exits non-zero and prints an error for a malformed program on stdin" do
    _, err, status = run_cli(stdin: "(+ 1")
    status.success?.should be_false
    err.should contain("Error:")
  end

  it "exits non-zero and prints an error when the file argument doesn't exist" do
    _, err, status = run_cli(["/nonexistent/path/does-not-exist.scm"])
    status.success?.should be_false
    err.should contain("Error:")
  end

  it "evaluates a runtime error from a file with a non-zero exit" do
    file = File.tempfile("main_spec_err", ".scm") do |io|
      io.print("(import (scheme base)) (car 1)")
    end
    begin
      _, err, status = run_cli([file.path])
      status.success?.should be_false
      err.should contain("Error:")
    ensure
      File.delete(file.path)
    end
  end

  it "(exit N) exits the real binary with code N, stopping before later forms" do
    out, err, status = run_cli(stdin: %((import (scheme base) (scheme write) (scheme process-context)) (display "before") (exit 3) (display "after")))
    status.exit_code.should eq(3)
    out.should eq("before")
    err.should eq("")
  end

  it "(exit) with no arguments exits with code 0" do
    out, _, status = run_cli(stdin: %((import (scheme base) (scheme write) (scheme process-context)) (display "done") (exit)))
    status.success?.should be_true
    out.should eq("done")
  end

  it "--profile table runs a file normally and prints a profiling report after it" do
    file = File.tempfile("main_spec_profile", ".scm") do |io|
      io.print(<<-SCHEME)
        (import (scheme base) (scheme write))
        (define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
        (display (fib 24))
        (newline)
        SCHEME
    end
    begin
      out, err, status = run_cli(["--profile", "table", file.path])
      status.success?.should be_true
      err.should eq("")
      out.should contain("46368\n") # (fib 24) -- the script's own ordinary output, unaffected
      out.should contain("(x1)")
      out.should contain("hot Scheme functions")
      out.should contain("hot Crystal frames")
    ensure
      File.delete(file.path)
    end
  end

  it "--profile requires \"table\" as its first argument" do
    _, err, status = run_cli(["--profile", "nonsense", "somefile.scm"])
    status.success?.should be_false
    err.should contain("Usage: creme --profile table <file.scm>")
  end

  it "--profile table requires a file argument" do
    _, err, status = run_cli(["--profile", "table"])
    status.success?.should be_false
    err.should contain("Usage: creme --profile table <file.scm>")
  end

  it "-- runs the given file as a plain script, unaffected by any of creme's own flags" do
    file = File.tempfile("main_spec_dashdash", ".scm") do |io|
      io.print(%((import (scheme base) (scheme write)) (display "hello from --") (newline)))
    end
    begin
      out, err, status = run_cli(["--", file.path])
      status.success?.should be_true
      out.should eq("hello from --\n")
      err.should eq("")
    ensure
      File.delete(file.path)
    end
  end

  it "-- hands a literal --profile through to the script's own (command-line)" do
    file = File.tempfile("main_spec_dashdash_profile", ".scm") do |io|
      io.print(<<-SCHEME)
        (import (scheme base) (scheme write) (scheme process-context))
        (display (command-line))
        (newline)
        SCHEME
    end
    begin
      out, err, status = run_cli(["--", file.path, "--profile"])
      status.success?.should be_true
      err.should eq("")
      out.should contain(%(--profile))
    ensure
      File.delete(file.path)
    end
  end

  it "-- requires a file argument" do
    _, err, status = run_cli(["--"])
    status.success?.should be_false
    err.should contain("Usage: creme -- <file.scm>")
  end
end
