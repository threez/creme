require "../spec_helper"
require "file_utils"

private def with_tmp_dir(&)
  dir = File.tempname("crisp-backtrace-spec", "")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe "backtraces" do
  it "attaches no frames/position to a parse error (raised before any eval)" do
    ex = begin
      LISP::Reader.read_all(")")
      nil
    rescue e : LISP::LispParseError
      e
    end
    ex.should_not be_nil
    ex = ex.not_nil!
    ex.frames.should eq([] of LISP::Frame)
    ex.pos.should be_nil
  end

  it "captures the raising builtin's own position for a non-tail call" do
    interp = LISP::Interpreter.new
    ex = begin
      LISP.run_source(interp, "(define (f x) (+ 1 (car x))) (f 5)", source_name: "prog.lisp")
      nil
    rescue e : LISP::LispRuntimeError
      e
    end
    ex.should_not be_nil
    ex = ex.not_nil!
    ex.message.should match(/car: expected pair/)
    ex.pos.should_not be_nil
    ex.pos.not_nil!.file.should eq("prog.lisp")
    ex.frames.map(&.name).should contain("car")
    ex.frames.map(&.name).should contain("f")
  end

  it "collapses deep tail recursion to a single frame instead of one per call" do
    interp = LISP::Interpreter.new
    ex = begin
      LISP.run_source(interp, "(define (loop n) (if (= n 0) (car 5) (loop (- n 1)))) (loop 50)")
      nil
    rescue e : LISP::LispRuntimeError
      e
    end
    ex.should_not be_nil
    ex.not_nil!.frames.count { |f| f.name == "loop" }.should eq(1)
  end

  it "names each file across a require-path call chain, innermost first" do
    with_tmp_dir do |raw_dir|
      dir = File.realpath(raw_dir)
      File.write(File.join(dir, "helper.lisp"), "(define (risky x)\n  (car x))\n")
      File.write(File.join(dir, "main.lisp"), <<-LISP)
        (require "helper.lisp")
        (define (wrapper x)
          (+ 1 (helper:risky x)))
        (wrapper 5)
        LISP

      interp = LISP::Interpreter.new
      ex = begin
        LISP.run_file(interp, File.join(dir, "main.lisp"))
        nil
      rescue e : LISP::LispRuntimeError
        e
      end
      ex.should_not be_nil
      ex = ex.not_nil!

      names = ex.frames.map(&.name)
      names.should contain("car")
      names.should contain("risky")
      names.should contain("wrapper")

      risky_frame = ex.frames.find { |f| f.name == "risky" }.not_nil!
      risky_frame.pos.not_nil!.file.should eq(File.join(dir, "main.lisp"))

      wrapper_frame = ex.frames.find { |f| f.name == "wrapper" }.not_nil!
      wrapper_frame.pos.not_nil!.file.should eq(File.join(dir, "main.lisp"))

      car_frame = ex.frames.find { |f| f.name == "car" }.not_nil!
      car_frame.pos.not_nil!.file.should eq(File.join(dir, "helper.lisp"))
    end
  end
end
