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

  it "--self-hosted runs a file via the self-hosted compiler, matching a plain run" do
    file = File.tempfile("main_spec_self_hosted", ".scm") do |io|
      io.print(<<-SCHEME)
        (import (scheme base) (scheme write))
        (define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))
        (display (fact 10))
        (newline)
        SCHEME
    end
    begin
      native_out, native_err, native_status = run_cli([file.path])
      self_hosted_out, self_hosted_err, self_hosted_status = run_cli(["--self-hosted", file.path])

      self_hosted_status.success?.should be_true
      self_hosted_out.should eq(native_out)
      self_hosted_err.should eq(native_err)
      native_status.success?.should be_true
    ensure
      File.delete(file.path)
    end
  end

  it "--self-hosted requires a file argument" do
    _, err, status = run_cli(["--self-hosted"])
    status.success?.should be_false
    err.should contain("Usage: creme --self-hosted <file.scm>")
  end

  it "--self-hosted exits non-zero and prints an error for a runtime error" do
    file = File.tempfile("main_spec_self_hosted_err", ".scm") do |io|
      io.print("(import (scheme base)) (car 1)")
    end
    begin
      _, err, status = run_cli(["--self-hosted", file.path])
      status.success?.should be_false
      err.should contain("Error:")
    ensure
      File.delete(file.path)
    end
  end

  it "--disassemble prints the bytecode of an already-compiled --emit-cvm file, including nested closures" do
    src_file = File.tempfile("main_spec_disasm", ".scm") do |io|
      io.print(%((import (scheme base) (scheme write)) (define (fact n) (if (= n 0) 1 (* n (fact (- n 1))))) (display (fact 5))))
    end
    cvmc_file = File.tempname("main_spec_disasm", ".cvmc")
    begin
      _, emit_err, emit_status = run_cli(["--emit-cvm", src_file.path, cvmc_file])
      emit_status.success?.should be_true
      emit_err.should eq("")

      out, err, status = run_cli(["--disassemble", cvmc_file])
      status.success?.should be_true
      err.should eq("")
      out.should contain("DefGlobal")
      out.should contain("; fact")
      out.should contain("> proto 0 (fact)")
      out.should contain("TestEqImm")
    ensure
      File.delete(src_file.path)
      File.delete(cvmc_file) if File.exists?(cvmc_file)
    end
  end

  it "--disassemble requires a file argument" do
    _, err, status = run_cli(["--disassemble"])
    status.success?.should be_false
    err.should contain("Usage: creme --disassemble <file.cvmc>")
  end

  it "--disassemble exits non-zero and prints an error when the file doesn't exist" do
    _, err, status = run_cli(["--disassemble", "/nonexistent/path/does-not-exist.cvmc"])
    status.success?.should be_false
    err.should contain("no such file")
  end

  it "--disassemble exits non-zero and prints an error for a non-SCB1 file" do
    file = File.tempfile("main_spec_disasm_bad", ".cvmc") do |io|
      io.print("not a real chunk")
    end
    begin
      _, err, status = run_cli(["--disassemble", file.path])
      status.success?.should be_false
      err.should contain("bad magic")
    ensure
      File.delete(file.path)
    end
  end
end
