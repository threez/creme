require "../spec_helper"
require "file_utils"

private def with_tmp_dir(&)
  dir = File.tempname("creme-backtrace-spec", "")
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
      Scheme::Reader.read_all(")")
      nil
    rescue e : Scheme::SchemeParseError
      e
    end
    ex.should_not be_nil
    if ex
      ex.frames.should eq([] of Scheme::Frame)
      ex.pos.should be_nil
    end
  end

  it "captures the raising builtin's own position for a non-tail call" do
    interp = Scheme::Interpreter.new
    ex = begin
      Scheme.run_source(interp, "(define (f x) (+ 1 (car x))) (f 5)", source_name: "prog.scm")
      nil
    rescue e : Scheme::SchemeRuntimeError
      e
    end
    ex.should_not be_nil
    if ex
      ex.message.should match(/car: expected pair/)
      pos = ex.pos
      pos.should_not be_nil
      pos.try(&.file).should eq("prog.scm")
      ex.frames.map(&.name).should contain("car")
      ex.frames.map(&.name).should contain("f")
    end
  end

  it "collapses deep tail recursion to a single frame instead of one per call" do
    interp = Scheme::Interpreter.new
    ex = begin
      Scheme.run_source(interp, "(define (loop n) (if (= n 0) (car 5) (loop (- n 1)))) (loop 50)")
      nil
    rescue e : Scheme::SchemeRuntimeError
      e
    end
    ex.should_not be_nil
    ex.try(&.frames.count { |frame| frame.name == "loop" }).should eq(1)
  end

  it "names each file across an imported-library call chain, innermost first" do
    with_tmp_dir do |raw_dir|
      dir = File.realpath(raw_dir)
      File.write(File.join(dir, "helper.sld"), <<-SLD)
        (define-library (helper)
          (export risky)
          (import (scheme base))
          (begin
            (define (risky x)
              (car x))))
        SLD
      File.write(File.join(dir, "main.scm"), <<-SCHEME)
        (import (helper) (scheme base))
        (define (wrapper x)
          (+ 1 (risky x)))
        (wrapper 5)
        SCHEME

      interp = Scheme::Interpreter.new(library_search_path: [dir])
      ex = begin
        Scheme.run_file(interp, File.join(dir, "main.scm"))
        nil
      rescue e : Scheme::SchemeRuntimeError
        e
      end
      ex.should_not be_nil
      if ex
        names = ex.frames.map(&.name)
        names.should contain("car")
        names.should contain("risky")
        names.should contain("wrapper")

        risky_frame = ex.frames.find! { |frame| frame.name == "risky" }
        risky_frame.pos.try(&.file).should eq(File.join(dir, "main.scm"))

        wrapper_frame = ex.frames.find! { |frame| frame.name == "wrapper" }
        wrapper_frame.pos.try(&.file).should eq(File.join(dir, "main.scm"))

        car_frame = ex.frames.find! { |frame| frame.name == "car" }
        car_frame.pos.try(&.file).should eq(File.join(dir, "helper.sld"))
      end
    end
  end
end
