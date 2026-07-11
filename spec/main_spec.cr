require "./spec_helper"

private BIN_PATH = File.join(Dir.current, "bin", "crisp_spec")

Spec.before_suite do
  build = Process.run("crystal", ["build", "src/main.cr", "-o", BIN_PATH])
  raise "failed to build crisp for main_spec" unless build.success?
end

private def run_cli(args : Array(String) = [] of String, stdin : String = "") : {String, String, Process::Status}
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(BIN_PATH, args, input: IO::Memory.new(stdin), output: output, error: error)
  {output.to_s, error.to_s, status}
end

describe "main.cr (CLI)" do
  it "reads a program from stdin (non-tty) and evaluates it" do
    out, err, status = run_cli(stdin: "(println (+ 1 2))")
    status.success?.should be_true
    out.should eq("3\n")
    err.should eq("")
  end

  it "runs a file argument and exits 0" do
    file = File.tempfile("main_spec", ".lisp") do |io|
      io.print(%((println "hello from file")))
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
    out.should contain("crisp — a LISP interpreter (Crystal)")
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
    _, err, status = run_cli(["/nonexistent/path/does-not-exist.lisp"])
    status.success?.should be_false
    err.should contain("Error:")
  end

  it "evaluates a runtime error from a file with a non-zero exit" do
    file = File.tempfile("main_spec_err", ".lisp") do |io|
      io.print("(car 1)")
    end
    begin
      _, err, status = run_cli([file.path])
      status.success?.should be_false
      err.should contain("Error:")
    ensure
      File.delete(file.path)
    end
  end
end
