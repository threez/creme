require "../../spec_helper"
require "file_utils"

# (scheme base) doesn't exist as a real importable library until Stage 2, so
# these Stage-1 specs bootstrap a minimal stand-in, (test base), backed
# directly by @global — exercising the same register_library path Stage 2
# uses for the real thing. Every library body under test must explicitly
# (import (test base)) to see +/string-append/etc., since library Envs are
# deliberately parentless (see interpreter/library.cr's doc comment).
private def new_interp : Creme::Interpreter
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  exports = %w[+ - * < = string-append car cdr cons list vector-set! vector-ref vector-length make-vector].to_h { |name| {name, name} }
  interp.register_library(["test", "base"], interp.global, exports)
  interp
end

# Bootstraps a (scheme base)-equivalent (including special forms like set!,
# do, let — see Creme::Interpreter::SPECIAL_FORM_NAMES) for tests that need
# the real R7RS library name, e.g. exercising R7RS's own spec examples
# verbatim. (scheme base) becomes a genuine always-on library in Stage 2;
# until then this mirrors what that stage will register.
private def new_scheme_base_interp : Creme::Interpreter
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  exports = (%w[
    + - * < = > <= >= string-append car cdr cons list
    vector-set! vector-ref vector-length make-vector display newline
  ] + Creme::Interpreter::SPECIAL_FORM_NAMES).uniq.to_h { |name| {name, name} }
  interp.register_library(["scheme", "base"], interp.global, exports)
  interp
end

private def run(src : String) : Creme::SchemeValue
  Creme.run_source(new_interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

private def with_tmp_dir(&)
  dir = File.tempname("creme-library-spec", "")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe "define-library / import" do
  it "defines a library and imports a plain binding by name" do
    w(<<-SCM).should eq("3")
      (define-library (test math-lib)
        (export add)
        (import (test base))
        (begin (define (add a b) (+ a b))))
      (import (test math-lib))
      (add 1 2)
    SCM
  end

  it "keeps non-exported bindings invisible to the importer" do
    expect_raises(Creme::SchemeRuntimeError, /unbound variable: helper/) do
      run(<<-SCM)
        (define-library (test hidden)
          (export add)
          (import (test base))
          (begin
            (define (helper x) (* x 2))
            (define (add a b) (helper (+ a b)))))
        (import (test hidden))
        helper
      SCM
    end
  end

  it "supports (only ...) import sets" do
    w(<<-SCM).should eq("3")
      (define-library (test two-exports)
        (export add sub)
        (import (test base))
        (begin
          (define (add a b) (+ a b))
          (define (sub a b) (- a b))))
      (import (only (test two-exports) add))
      (add 1 2)
    SCM

    expect_raises(Creme::SchemeRuntimeError, /unbound variable: sub/) do
      run(<<-SCM)
        (define-library (test two-exports-b)
          (export add sub)
          (import (test base))
          (begin
            (define (add a b) (+ a b))
            (define (sub a b) (- a b))))
        (import (only (test two-exports-b) add))
        sub
      SCM
    end
  end

  it "supports (except ...) import sets" do
    expect_raises(Creme::SchemeRuntimeError, /unbound variable: sub/) do
      run(<<-SCM)
        (define-library (test except-lib)
          (export add sub)
          (import (test base))
          (begin
            (define (add a b) (+ a b))
            (define (sub a b) (- a b))))
        (import (except (test except-lib) sub))
        sub
      SCM
    end
  end

  it "except genuinely removes a binding rather than just hiding a re-export — a library body can shadow it via rename" do
    w(<<-SCM).should eq("42")
      (define-library (test overlay)
        (export put!)
        (import (test base))
        (begin (define (put! v) v)))
      (define-library (test shadowed)
        (export run)
        (import (except (test base) car) (rename (test overlay) (put! car)))
        (begin (define (run x) (car x))))
      (import (test shadowed))
      (run 42)
    SCM
  end

  it "supports (prefix ...) import sets" do
    w(<<-SCM).should eq("3")
      (define-library (test prefix-lib)
        (export add)
        (import (test base))
        (begin (define (add a b) (+ a b))))
      (import (prefix (test prefix-lib) math-))
      (math-add 1 2)
    SCM
  end

  it "supports (rename ...) import sets" do
    w(<<-SCM).should eq("3")
      (define-library (test rename-lib)
        (export add)
        (import (test base))
        (begin (define (add a b) (+ a b))))
      (import (rename (test rename-lib) (add plus)))
      (plus 1 2)
    SCM
  end

  it "supports (export (rename internal external)) in the library itself" do
    w(<<-SCM).should eq("3")
      (define-library (test rename-export-lib)
        (export (rename internal-add add))
        (import (test base))
        (begin (define (internal-add a b) (+ a b))))
      (import (test rename-export-lib))
      (add 1 2)
    SCM
  end

  it "raises for an unknown library" do
    expect_raises(Creme::SchemeRuntimeError, /import: unknown library \(no such library\)/) do
      run("(import (no such library))")
    end
  end

  it "is idempotent — re-evaluating the same define-library is a no-op returning the name" do
    w(<<-SCM).should eq("(test idempotent-lib)")
      (define-library (test idempotent-lib)
        (export add)
        (import (test base))
        (begin (define (add a b) (+ a b))))
      (define-library (test idempotent-lib)
        (export add)
        (import (test base))
        (begin (define (add a b) (+ a b))))
      (import (test idempotent-lib))
      (add 1 2)
      '(test idempotent-lib)
    SCM
  end

  it "splices a matched cond-expand clause's declarations into the library body" do
    w(<<-SCM).should eq("1")
      (define-library (test cond-expand-lib)
        (export x)
        (cond-expand (else (begin (define x 1)))))
      (import (test cond-expand-lib))
      x
    SCM
  end

  it "reads and evaluates an included file's forms against the library's own Env" do
    with_tmp_dir do |dir|
      File.write(File.join(dir, "x.scm"), "(define x 1)")
      interp = new_interp
      interp.push_load_dir(dir)
      Creme.run_source(interp, <<-SCM).write_string.should eq("1")
        (define-library (test include-lib)
          (export x)
          (include "x.scm"))
        (import (test include-lib))
        x
      SCM
    end
  end

  describe "file-based (.sld) library resolution" do
    it "resolves (a b) to a/b.sld under library_search_path" do
      with_tmp_dir do |dir|
        Dir.mkdir_p(File.join(dir, "greet"))
        File.write(File.join(dir, "greet", "hello.sld"), <<-SLD)
          (define-library (greet hello)
            (export hello)
            (import (test base))
            (begin (define (hello name) (string-append "hi " name))))
        SLD
        interp = new_interp
        interp.library_search_path = [dir]
        result = Creme.run_source(interp, %[(import (greet hello)) (hello "Ada")])
        result.write_string.should eq(%("hi Ada"))
      end
    end

    it "raises when the .sld file's own library name doesn't match the requested name" do
      with_tmp_dir do |dir|
        File.write(File.join(dir, "mismatch.sld"), <<-SLD)
          (define-library (something else)
            (export x)
            (import (test base))
            (begin (define x 1)))
        SLD
        interp = new_interp
        interp.library_search_path = [dir]
        expect_raises(Creme::SchemeRuntimeError, /expected \(mismatch\)/) do
          Creme.run_source(interp, "(import (mismatch))")
        end
      end
    end

    it "raises when the .sld file contains more than one top-level form" do
      with_tmp_dir do |dir|
        File.write(File.join(dir, "extra.sld"), <<-SLD)
          (define-library (extra)
            (export x)
            (import (test base))
            (begin (define x 1)))
          (define y 2)
        SLD
        interp = new_interp
        interp.library_search_path = [dir]
        expect_raises(Creme::SchemeRuntimeError, /expected exactly one \(define-library/) do
          Creme.run_source(interp, "(import (extra))")
        end
      end
    end
  end

  describe "circular import detection" do
    it "raises a clear error instead of infinite-looping" do
      with_tmp_dir do |dir|
        File.write(File.join(dir, "a.sld"), <<-SLD)
          (define-library (a)
            (export x)
            (import (b))
            (begin (define x 1)))
        SLD
        File.write(File.join(dir, "b.sld"), <<-SLD)
          (define-library (b)
            (export y)
            (import (a))
            (begin (define y 2)))
        SLD
        interp = new_interp
        interp.library_search_path = [dir]
        expect_raises(Creme::SchemeRuntimeError, /circular library dependency/) do
          Creme.run_source(interp, "(import (a))")
        end
      end
    end
  end

  describe "special forms are shadowable/importable identifiers (R7RS section 5.6 example)" do
    it "a library can export a procedure renamed as set!, and importing code can exclude the base set! in favor of it" do
      interp = new_scheme_base_interp
      interp.stdout = out = IO::Memory.new
      Creme.run_source(interp, File.read("#{__DIR__}/../../fixtures/r7rs_grid_life.scm"))
      out.to_s.should eq("alive\n#f\n")
    end

    it "a special form shadowed by a local define is used in place of the built-in for the rest of that scope" do
      interp = new_scheme_base_interp
      Creme.run_source(interp, "(import (scheme base))").should_not be_nil
      Creme.run_source(interp, "(let ((if list)) (if 1 2 3))").write_string.should eq("(1 2 3)")
    end
  end
end
