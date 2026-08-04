require "../../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (creme bootstrap)) #{src}").write_string
end

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (creme bootstrap)) #{src}")
end

# Compiles `source` the same way Creme.run_source would, serializes the
# resulting Chunk to "ICE" bytes via ChunkSerializer, and hands those bytes
# back as a SchemeBlob argument for `(load-chunk-bytes ...)` to consume —
# exercising the exact round-trip a self-hosted, Scheme-written compiler will
# eventually produce on its own.
private def compiled_bytes(interp : Creme::Interpreter, env : Creme::Env, source : String) : Creme::SchemeBlob
  forms = Creme::Reader.read_all(source)
  node = interp.analyze(Creme::Cons.new(Creme::SchemeSym.of("begin"), Creme.a_to_list(forms)), env)
  chunk = Creme::BytecodeCompiler.compile_program([node])
  Creme::SchemeBlob.new(Creme::ChunkSerializer.serialize(chunk))
end

describe "bootstrap module" do
  it "runs a deserialized chunk that matches direct evaluation" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    Creme.run_source(interp, "(import (creme bootstrap))")
    blob = compiled_bytes(interp, interp.global, "(+ 1 2 3)")
    interp.global.define("chunk-bytes", blob)
    run_result = Creme.run_source(interp, "(load-chunk-bytes chunk-bytes)")
    run_result.write_string.should eq("6")
  end

  it "round-trips closures, recursion, and strings/vectors" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    Creme.run_source(interp, "(import (creme bootstrap))")
    src = <<-SCM
    (define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))
    (define v (vector 1 2 3))
    (vector-set! v 1 (fact 5))
    (string-append "sum=" (number->string (+ (vector-ref v 0) (vector-ref v 1) (vector-ref v 2))))
    SCM
    blob = compiled_bytes(interp, interp.global, src)
    interp.global.define("chunk-bytes", blob)
    result = Creme.run_source(interp, "(load-chunk-bytes chunk-bytes)")
    result.write_string.should eq(%("sum=124"))
  end

  it "raises a clean error on garbage bytes" do
    expect_raises(Creme::SchemeRuntimeError, /load-chunk-bytes/) do
      run(%((load-chunk-bytes (make-bytevector 8 0))))
    end
  end

  it "import! copies a library's bindings into the global env" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    Creme.run_source(interp, "(import (creme bootstrap))")
    interp.global.get?("regexp-matches?").should be_nil
    Creme.run_source(interp, %((import! (quote ((creme regex))))))
    Creme.run_source(interp, %((regexp-matches? (regexp "a+") "aaa"))).write_string.should eq("#t")
  end

  it "import! applies only/except/prefix import-set filters" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    Creme.run_source(interp, "(import (creme bootstrap))")
    Creme.run_source(interp, %((import! (quote ((prefix (only (creme regex) regexp) rx-))))))
    interp.global.get?("rx-regexp").should_not be_nil
    interp.global.get?("regexp-matches?").should be_nil
  end

  it "expand-if-macro detects and expands a defmacro-defined global" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    Creme.run_source(interp, "(import (creme bootstrap)) (defmacro my-list2 args (cons 'list args))")
    result = Creme.run_source(interp, %((expand-if-macro '(my-list2 1 2 3))))
    result.write_string.should eq("(#t list 1 2 3)")
  end

  it "expand-if-macro detects and expands a define-syntax-defined global" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    Creme.run_source(interp, %((import (creme bootstrap)) (define-syntax my-swap! (syntax-rules () ((_ a b) (let ((tmp a)) (set! a b) (set! b tmp)))))))
    result = Creme.run_source(interp, %((expand-if-macro '(my-swap! x y))))
    result.write_string.should eq("(#t let ((tmp x)) (set! x y) (set! y tmp))")
  end

  it "expand-if-macro returns #f for an ordinary procedure or unbound name" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    Creme.run_source(interp, "(import (creme bootstrap))")
    Creme.run_source(interp, %((expand-if-macro '(+ 1 2)))).write_string.should eq("#f")
    Creme.run_source(interp, %((expand-if-macro '(totally-unbound-name 1 2)))).write_string.should eq("#f")
  end
end
