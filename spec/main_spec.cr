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
end
