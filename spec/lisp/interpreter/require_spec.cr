require "../../spec_helper"
require "file_utils"

private def run(src : String) : LISP::LispValue
  interp = LISP::Interpreter.new
  LISP.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "require" do
  it "loads a module and makes qualified names callable" do
    w("(require 'math) (math:sin 0)").should eq("0.0")
  end

  it "also accepts a bare (unquoted) symbol" do
    w("(require math) (math:sin 0)").should eq("0.0")
  end

  it "is idempotent" do
    w("(require 'math) (require 'math) (math:sin 0)").should eq("0.0")
  end

  it "raises on an unknown module" do
    expect_raises(LISP::LispRuntimeError, /require: unknown module 'nope'/) do
      run("(require 'nope)")
    end
  end

  it "raises when using a qualified symbol from a package that was never required" do
    expect_raises(LISP::LispRuntimeError, /unbound package: math/) do
      run("(math:sin 0)")
    end
  end

  it "raises when the required symbol doesn't exist in the package" do
    expect_raises(LISP::LispRuntimeError, /unbound variable: nope/) do
      run("(require 'math) (math:nope)")
    end
  end

  it "raises for a non-symbol, non-string argument" do
    expect_raises(LISP::LispRuntimeError, /require: argument must be a symbol or a string path/) do
      run(%((require 5)))
    end
  end
end

describe "allowed_modules" do
  it "defaults to nil (unrestricted) — any known module can be required" do
    interp = LISP::Interpreter.new
    interp.allowed_modules.should be_nil
    LISP.run_source(interp, "(require 'math) (math:sin 0)").as(LISP::LispFloat).value.should eq(0.0)
  end

  it "raises 'not permitted' for a real module outside the allowlist" do
    interp = LISP::Interpreter.new(allowed_modules: ["json"])
    expect_raises(LISP::LispRuntimeError, /require: module 'process' is not permitted/) do
      LISP.run_source(interp, "(require 'process)")
    end
  end

  it "still allows a module inside the allowlist" do
    interp = LISP::Interpreter.new(allowed_modules: ["math"])
    LISP.run_source(interp, "(require 'math) (math:sin 0)").as(LISP::LispFloat).value.should eq(0.0)
  end

  it "raises 'unknown module' rather than 'not permitted' for a name that is allowlisted but doesn't exist" do
    interp = LISP::Interpreter.new(allowed_modules: ["nope"])
    expect_raises(LISP::LispRuntimeError, /require: unknown module 'nope'/) do
      LISP.run_source(interp, "(require 'nope)")
    end
  end
end

private def with_tmp_dir(&)
  dir = File.tempname("crisp-require-spec", "")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe "path-based require" do
  it "loads a .lisp file and makes its top-level defines qualified-callable" do
    with_tmp_dir do |dir|
      File.write(File.join(dir, "greet.lisp"), %[(define (hello name) (string-append "hi " name))])
      interp = LISP::Interpreter.new
      w = LISP.run_source(interp, %[(require "#{dir}/greet.lisp") (greet:hello "Ada")]).write_string
      w.should eq(%("hi Ada"))
    end
  end

  it "resolves nested relative requires against the requiring file's own directory, not the caller's" do
    with_tmp_dir do |dir|
      Dir.mkdir_p(File.join(dir, "sub"))
      File.write(File.join(dir, "sub", "leaf.lisp"), "(define answer 42)")
      # top.lisp lives in sub/, so its relative "leaf.lisp" require must
      # resolve against sub/, not against dir/ (where the top-level caller is).
      File.write(File.join(dir, "sub", "top.lisp"), %[(require "leaf.lisp") (define value leaf:answer)])
      interp = LISP::Interpreter.new
      LISP.run_source(interp, %[(require "#{dir}/sub/top.lisp") top:value]).write_string.should eq("42")
    end
  end

  it "is idempotent across re-requires of the same file regardless of relative spelling" do
    with_tmp_dir do |dir|
      File.write(File.join(dir, "m.lisp"), "(define x 1)")
      interp = LISP::Interpreter.new
      LISP.run_source(interp, %[(require "#{dir}/m.lisp") (require "#{dir}/./m.lisp") m:x]).write_string.should eq("1")
    end
  end

  it "raises when two different files derive the same module name" do
    with_tmp_dir do |dir|
      Dir.mkdir_p(File.join(dir, "a"))
      Dir.mkdir_p(File.join(dir, "b"))
      File.write(File.join(dir, "a", "m.lisp"), "(define x 1)")
      File.write(File.join(dir, "b", "m.lisp"), "(define x 2)")
      interp = LISP::Interpreter.new
      expect_raises(LISP::LispRuntimeError, /require: module 'm' already bound to/) do
        LISP.run_source(interp, %[(require "#{dir}/a/m.lisp") (require "#{dir}/b/m.lisp")])
      end
    end
  end

  it "raises when the derived name collides with a built-in Crystal module" do
    with_tmp_dir do |dir|
      File.write(File.join(dir, "math.lisp"), "(define x 1)")
      interp = LISP::Interpreter.new
      expect_raises(LISP::LispRuntimeError, /require: module 'math' already bound to a built-in module/) do
        LISP.run_source(interp, %[(require 'math) (require "#{dir}/math.lisp")])
      end
    end
  end

  it "raises 'file not found' for a missing path" do
    interp = LISP::Interpreter.new
    expect_raises(LISP::LispRuntimeError, /require: file not found/) do
      LISP.run_source(interp, %[(require "/no/such/file.lisp")])
    end
  end

  it "a Lisp-authored module can use prelude/global bindings (unlike Crystal-native modules)" do
    with_tmp_dir do |dir|
      File.write(File.join(dir, "listy.lisp"), "(define (double-all lst) (map (lambda (x) (* 2 x)) lst))")
      interp = LISP::Interpreter.new
      LISP.run_source(interp, %[(require "#{dir}/listy.lisp") (listy:double-all '(1 2 3))]).write_string.should eq("(2 4 6)")
    end
  end

  describe "module_load_paths sandboxing" do
    it "defaults to nil (unrestricted)" do
      LISP::Interpreter.new.module_load_paths.should be_nil
    end

    it "denies all path-based requires by default under .sandboxed" do
      interp = LISP::Interpreter.sandboxed
      interp.module_load_paths.should eq([] of String)
      with_tmp_dir do |dir|
        File.write(File.join(dir, "m.lisp"), "(define x 1)")
        expect_raises(LISP::LispRuntimeError, /require: path '.*' is not permitted/) do
          LISP.run_source(interp, %[(require "#{dir}/m.lisp")])
        end
      end
    end

    it "allows loading from a configured base directory" do
      with_tmp_dir do |dir|
        File.write(File.join(dir, "m.lisp"), "(define x 1)")
        interp = LISP::Interpreter.sandboxed(module_load_paths: [dir])
        LISP.run_source(interp, %[(require "#{dir}/m.lisp") m:x]).write_string.should eq("1")
      end
    end

    it "rejects a path that escapes the configured base directory via traversal" do
      with_tmp_dir do |dir|
        Dir.mkdir_p(File.join(dir, "allowed"))
        File.write(File.join(dir, "outside.lisp"), "(define x 1)")
        interp = LISP::Interpreter.sandboxed(module_load_paths: [File.join(dir, "allowed")])
        expect_raises(LISP::LispRuntimeError, /require: path '.*' is not permitted/) do
          LISP.run_source(interp, %[(require "#{dir}/allowed/../outside.lisp")])
        end
      end
    end
  end
end

describe "#available_modules" do
  it "lists every Crystal-native module the interpreter can require" do
    interp = LISP::Interpreter.new
    interp.available_modules.should contain("math")
    interp.available_modules.should contain("json")
    interp.available_modules.should contain("sql")
    interp.available_modules.should_not contain("sxql")
    interp.available_modules.size.should eq(17)
  end

  it "also lists .lisp files discoverable in module_search_path" do
    interp = LISP::Interpreter.new(module_search_path: ["./modules"])
    interp.available_modules.should contain("sxql")
  end
end

describe "module_search_path" do
  it "defaults to empty — a bare-symbol require for a file-based module is unknown" do
    interp = LISP::Interpreter.new
    interp.module_search_path.should eq([] of String)
    expect_raises(LISP::LispRuntimeError, /require: unknown module 'sxql'/) do
      LISP.run_source(interp, "(require 'sxql)")
    end
  end

  it "resolves a bare-symbol require to a matching .lisp file in a configured search directory" do
    with_tmp_dir do |dir|
      File.write(File.join(dir, "greeter.lisp"), %[(define (hello name) (string-append "hi " name))])
      interp = LISP::Interpreter.new(module_search_path: [dir])
      w = LISP.run_source(interp, %[(require 'greeter) (greeter:hello "Ada")]).write_string
      w.should eq(%("hi Ada"))
    end
  end

  it "still honors allowed_modules for search-path-resolved modules" do
    with_tmp_dir do |dir|
      File.write(File.join(dir, "greeter.lisp"), "(define x 1)")
      interp = LISP::Interpreter.new(allowed_modules: ["math"], module_search_path: [dir])
      expect_raises(LISP::LispRuntimeError, /require: module 'greeter' is not permitted/) do
        LISP.run_source(interp, "(require 'greeter)")
      end
    end
  end
end
