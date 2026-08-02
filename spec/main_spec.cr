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

  it "--disassemble prints the bytecode of an already-compiled --emit-icecreme file, including nested closures" do
    src_file = File.tempfile("main_spec_disasm", ".scm") do |io|
      io.print(%((import (scheme base) (scheme write)) (define (fact n) (if (= n 0) 1 (* n (fact (- n 1))))) (display (fact 5))))
    end
    ice_file = File.tempname("main_spec_disasm", ".ice")
    begin
      _, emit_err, emit_status = run_cli(["--emit-icecreme", src_file.path, ice_file])
      emit_status.success?.should be_true
      emit_err.should eq("")

      out, err, status = run_cli(["--disassemble", ice_file])
      status.success?.should be_true
      err.should eq("")
      out.should contain("DefGlobal")
      out.should contain("; fact")
      out.should contain("> proto 0 (fact)")
      out.should contain("TestEqImm")
    ensure
      File.delete(src_file.path)
      File.delete(ice_file) if File.exists?(ice_file)
    end
  end

  it "--disassemble requires a file argument" do
    _, err, status = run_cli(["--disassemble"])
    status.success?.should be_false
    err.should contain("Usage: creme --disassemble <file.ice>")
  end

  it "--disassemble exits non-zero and prints an error when the file doesn't exist" do
    _, err, status = run_cli(["--disassemble", "/nonexistent/path/does-not-exist.ice"])
    status.success?.should be_false
    err.should contain("no such file")
  end

  it "--disassemble exits non-zero and prints an error for a non-ICE1 file" do
    file = File.tempfile("main_spec_disasm_bad", ".ice") do |io|
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

  # icecreme/icecreme (the standalone C11 prototype VM) is a separate, optionally-built
  # binary -- same "best effort" treatment bench/bench.scm and run_via_icecreme
  # (src/main.cr) already give it, since a fresh checkout on a machine
  # without a working C toolchain/GC dev package for it shouldn't fail the
  # whole Crystal spec suite. `make -C icecreme` here only actually rebuilds
  # anything the first time icecreme/icecreme doesn't exist yet or its sources
  # changed; a no-op run (the common case in CI, where it's already built)
  # is instant.
  describe "--icecreme (standalone C11 prototype VM)" do
    icecreme_bin = "icecreme/icecreme"
    Process.run("make", ["-C", "icecreme"], output: Process::Redirect::Close, error: Process::Redirect::Close)
    icecreme_available = File.exists?(icecreme_bin)

    unless icecreme_available
      puts "  (icecreme/icecreme could not be built in this environment -- skipping icecreme-specific regression tests)"
    end

    if icecreme_available
      # Regression test for a real bug: icecreme/hashtable.c's hash-table-ref
      # unconditionally cvm_apply'd its third argument as a thunk, but this
      # project's own hash-table-ref contract (src/creme/modules/creme/
      # hash_table.cr) allows a plain, non-procedure default too -- (creme
      # dao)'s dao-ref-keyword relies on exactly that (a plain #f default),
      # so any DAO-based script (e.g. competition/scheme/demo-todo/app.scm)
      # crashed under icecreme with "attempt to apply a non-procedure value" the
      # moment it read back a bool column. See icecreme/hashtable.c's
      # bi_hash_table_ref for the fix.
      it "hash-table-ref accepts a plain (non-procedure) default, not just a thunk" do
        file = File.tempfile("main_spec_icecreme_hashtable", ".scm") do |io|
          io.print(<<-SCHEME)
            (import (scheme base) (scheme write) (creme hash-table))
            (define h (make-hash-table))
            (display (hash-table-ref h 'missing #f))
            (newline)
            (hash-table-set! h 'k 42)
            (display (hash-table-ref h 'k #f))
            (newline)
            (display (hash-table-ref h 'missing2 (lambda () 'computed)))
            (newline)
            SCHEME
        end
        begin
          out, err, status = run_cli(["--icecreme", file.path])
          status.success?.should be_true
          out.should eq("#f\n42\ncomputed\n")
          # A plain --icecreme run always writes one stray "\n" to stderr
          # regardless of the script (a pre-existing icecreme quirk, unrelated
          # to this test) -- so only check no actual error text appears.
          err.strip.should eq("")
        ensure
          File.delete(file.path)
        end
      end

      # Regression test: icecreme/builtins.c was missing several R7RS vector
      # procedures ((creme html)/(creme css), among others, call these) --
      # vector-map, vector-for-each, vector-copy, vector-copy!,
      # vector-fill!, vector-append. Calling any of them aborted with
      # "unbound variable" before this fix.
      it "has the previously-missing R7RS vector procedures (vector-map/-for-each/-copy/-copy!/-fill!/-append)" do
        file = File.tempfile("main_spec_icecreme_vectors", ".scm") do |io|
          io.print(<<-SCHEME)
            (import (scheme base) (scheme write))
            (define v (vector 1 2 3))
            (vector-for-each (lambda (x) (display x)) v)
            (newline)
            (display (vector-map (lambda (x) (* x 2)) v))
            (newline)
            (define c (vector-copy v 1))
            (display c)
            (newline)
            (vector-fill! c 9)
            (display c)
            (newline)
            (display (vector-append v c))
            (newline)
            (vector-copy! v 0 c)
            (display v)
            (newline)
            SCHEME
        end
        begin
          out, err, status = run_cli(["--icecreme", file.path])
          status.success?.should be_true
          out.should eq("123\n#(2 4 6)\n#(2 3)\n#(9 9)\n#(1 2 3 9 9)\n#(9 9 3)\n")
          err.strip.should eq("")
        ensure
          File.delete(file.path)
        end
      end

      # Regression test for the flagship case icecreme/bootstrap.c's
      # bi_expand_if_macro exists for: a syntax-rules macro EXPORTED from a
      # .sld library, used by an importing script, compiled entirely ahead
      # of time via --emit-icecreme (not icecreme's own compiler-mode/REPL bridge,
      # which spec/scheme/modules/creme/bootstrap_spec.cr already covers).
      # --emit-icecreme's own emitter (icecreme_emitter.cr) re-analyzes each imported
      # library's body a second time purely for icecreme's benefit
      # (Interpreter#library_body_forms_for_icecreme) -- this confirms a
      # library-defined macro survives that second pass and is fully
      # expanded away before the resulting chunk ever runs, matching plain
      # Crystal-native execution's own macro-then-compile order.
      it "expands a syntax-rules macro exported from an imported .sld library" do
        lib_dir = File.join("modules", "main_spec_icecreme_macro_lib")
        Dir.mkdir_p(lib_dir)
        lib_file = File.join(lib_dir, "greet.sld")
        File.write(lib_file, <<-SCHEME)
          (define-library (main_spec_icecreme_macro_lib greet)
            (export my-if)
            (import (scheme base))
            (begin
              (define-syntax my-if
                (syntax-rules ()
                  ((_ c t e) (cond (c t) (else e)))))))
          SCHEME

        file = File.tempfile("main_spec_icecreme_macro", ".scm") do |io|
          io.print(<<-SCHEME)
            (import (scheme base) (scheme write) (main_spec_icecreme_macro_lib greet))
            (display (my-if #t 'yes 'no))
            (newline)
            (display (my-if #f 'yes 'no))
            (newline)
            SCHEME
        end
        begin
          out, err, status = run_cli(["--icecreme", file.path])
          status.success?.should be_true
          out.should eq("yes\nno\n")
          err.strip.should eq("")
        ensure
          File.delete(file.path)
          File.delete(lib_file)
          Dir.delete(lib_dir)
        end
      end

      # Regression test: collect_library_body_forms_for_icecreme (import.cr) used
      # to raise on `include`/`include-ci` inside a define-library, so any
      # library using either couldn't be compiled via --emit-icecreme at all.
      # Covers a nested relative include too (helper.scm itself includes
      # nested/deep.scm) to exercise the @load_dirs push this fix also
      # needed in library_body_forms_for_icecreme -- without it, the nested
      # include would resolve against the wrong directory.
      it "inlines include/include-ci declarations inside an imported .sld library" do
        lib_dir = File.join("modules", "main_spec_icecreme_include_lib")
        nested_dir = File.join(lib_dir, "nested")
        Dir.mkdir_p(nested_dir)
        lib_file = File.join(lib_dir, "lib.sld")
        helper_file = File.join(lib_dir, "helper.scm")
        deep_file = File.join(nested_dir, "deep.scm")
        File.write(lib_file, <<-SCHEME)
          (define-library (main_spec_icecreme_include_lib lib)
            (export greet loud-greet)
            (import (scheme base))
            (include "helper.scm"))
          SCHEME
        File.write(helper_file, <<-SCHEME)
          (define (greet name) (string-append "hi " name))
          (include "nested/deep.scm")
          SCHEME
        File.write(deep_file, <<-SCHEME)
          (define (loud-greet name) (string-append (greet name) "!"))
          SCHEME

        file = File.tempfile("main_spec_icecreme_include", ".scm") do |io|
          io.print(<<-SCHEME)
            (import (scheme base) (scheme write) (main_spec_icecreme_include_lib lib))
            (display (loud-greet "world"))
            (newline)
            SCHEME
        end
        begin
          out, err, status = run_cli(["--icecreme", file.path])
          status.success?.should be_true
          out.should eq("hi world!\n")
          err.strip.should eq("")
        ensure
          File.delete(file.path)
          File.delete(lib_file)
          File.delete(helper_file)
          File.delete(deep_file)
          Dir.delete(nested_dir)
          Dir.delete(lib_dir)
        end
      end

      # Regression test: icecreme's global table is one flat, name-interned array
      # with no per-library namespacing (icecreme/vm.c's cvm_global_intern) --
      # before icecreme_emitter.cr qualified a library's own internal
      # (non-exported) top-level names, two libraries each defining a
      # private helper of the same name would silently clobber each
      # other's global slot under --emit-icecreme (last DefGlobal wins), even
      # though the exact same program runs correctly under native (non-icecreme)
      # execution, where each library keeps a genuinely separate Env.
      it "keeps two libraries' same-named internal (non-exported) helpers from colliding under --emit-icecreme" do
        lib_a_dir = File.join("modules", "main_spec_icecreme_collide_a")
        lib_b_dir = File.join("modules", "main_spec_icecreme_collide_b")
        Dir.mkdir_p(lib_a_dir)
        Dir.mkdir_p(lib_b_dir)
        lib_a_file = File.join(lib_a_dir, "lib.sld")
        lib_b_file = File.join(lib_b_dir, "lib.sld")
        File.write(lib_a_file, <<-SCHEME)
          (define-library (main_spec_icecreme_collide_a lib)
            (export entry-a)
            (import (scheme base))
            (begin
              (define (helper x) (+ x 100))
              (define (entry-a n) (helper n))))
          SCHEME
        File.write(lib_b_file, <<-SCHEME)
          (define-library (main_spec_icecreme_collide_b lib)
            (export entry-b)
            (import (scheme base))
            (begin
              (define (helper x) (* x 1000))
              (define (entry-b n) (helper n))))
          SCHEME

        file = File.tempfile("main_spec_icecreme_collide", ".scm") do |io|
          io.print(<<-SCHEME)
            (import (scheme base) (scheme write) (main_spec_icecreme_collide_a lib) (main_spec_icecreme_collide_b lib))
            (display (entry-a 1))
            (newline)
            (display (entry-b 1))
            (newline)
            SCHEME
        end
        begin
          out, err, status = run_cli(["--icecreme", file.path])
          status.success?.should be_true
          out.should eq("101\n1000\n")
          err.strip.should eq("")
        ensure
          File.delete(file.path)
          File.delete(lib_a_file)
          File.delete(lib_b_file)
          Dir.delete(lib_a_dir)
          Dir.delete(lib_b_dir)
        end
      end

      # (creme ffi)'s generic dlopen/libffi bridge (src/creme/modules/
      # creme/ffi.cr, icecreme/creme_ffi.c) -- calls libm's real `sqrt` and
      # libc's real `abs`/`strlen`/`malloc`/`free` by name at runtime,
      # covering every MVP marshalled type (double, int32, string, and a
      # round-tripped pointer) on both backends identically, plus
      # ffi-pointer-ref/ffi-pointer-set!/ffi-type-size -- real struct-field
      # read/write at an explicit byte offset into the same malloc'd buffer --
      # plus ffi-gc-malloc/ffi-gc-free, a GC-heap-backed allocation source
      # needing no matching libc free.
      it "calls real native libc/libm functions by name via ffi-open/ffi-function/ffi-call" do
        # Sonames are platform-specific -- FreeBSD (this project's own dev
        # environment) uses BSD-style single-digit versioning, Linux/glibc
        # uses libX.so.6, Darwin has no libm/libc soname convention at all
        # (everything lives in libSystem).
        libm_soname = {% if flag?(:freebsd) %}
                        "libm.so.5"
                      {% elsif flag?(:linux) %}
                        "libm.so.6"
                      {% else %}
                        "libSystem.dylib"
                      {% end %}
        libc_soname = {% if flag?(:freebsd) %}
                        "libc.so.7"
                      {% elsif flag?(:linux) %}
                        "libc.so.6"
                      {% else %}
                        "libSystem.dylib"
                      {% end %}
        file = File.tempfile("main_spec_ffi", ".scm") do |io|
          io.print(<<-SCHEME)
            (import (scheme base) (scheme write) (creme ffi))
            (define libm (ffi-open "#{libm_soname}"))
            (define c-sqrt (ffi-function libm "sqrt" 'double '(double)))
            (display (ffi-call c-sqrt (list 16.0)))
            (newline)

            (define libc (ffi-open "#{libc_soname}"))
            (display (ffi-call (ffi-function libc "abs" 'int32 '(int32)) (list -42)))
            (newline)
            (display (ffi-call (ffi-function libc "strlen" 'int64 '(string)) (list "hello world")))
            (newline)

            (define c-malloc (ffi-function libc "malloc" 'pointer '(int64)))
            (define c-free (ffi-function libc "free" 'void '(pointer)))
            (define p (ffi-call c-malloc (list 16)))
            (display (ffi-pointer? p))
            (newline)
            (display (ffi-null-pointer? p))
            (newline)

            (display (ffi-type-size 'int32))
            (newline)
            (display (ffi-type-size 'int64))
            (newline)
            (ffi-pointer-set! p 0 'int32 42)
            (ffi-pointer-set! p 8 'double 2.5)
            (display (ffi-pointer-ref p 0 'int32))
            (newline)
            (display (ffi-pointer-ref p 8 'double))
            (newline)

            (ffi-call c-free (list p))

            (define gp (ffi-gc-malloc 16))
            (display (ffi-pointer? gp))
            (newline)
            (ffi-pointer-set! gp 0 'int64 777)
            (display (ffi-pointer-ref gp 0 'int64))
            (newline)
            (ffi-gc-free gp)

            (ffi-close libm)
            (ffi-close libc)
            SCHEME
        end
        begin
          out, err, status = run_cli([file.path])
          status.success?.should be_true
          out.should eq("4.0\n42\n11\n#t\n#f\n4\n8\n42\n2.5\n#t\n777\n")
          err.strip.should eq("")

          icecreme_out, icecreme_err, icecreme_status = run_cli(["--icecreme", file.path])
          icecreme_status.success?.should be_true
          icecreme_out.should eq("4.0\n42\n11\n#t\n#f\n4\n8\n42\n2.5\n#t\n777\n")
          icecreme_err.strip.should eq("")
        ensure
          File.delete(file.path)
        end
      end
    end
  end
end
