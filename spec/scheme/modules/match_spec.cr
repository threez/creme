require "../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (creme match)) #{src}").write_string
end

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (creme match)) #{src}")
end

private def define_types(src : String) : String
  <<-SCHEME
    (define-record-type <ping> (make-ping from) ping? (from ping-from))
    (define-record-type <pong> (make-pong) pong?)
    #{src}
    SCHEME
end

describe "match module" do
  it "dispatches on a record's own predicate and binds fields positionally" do
    w(define_types(%((match (make-ping 42) ((ping? from) from) (else 'nope))))).should eq("42")
  end

  it "supports a zero-field pattern" do
    w(define_types(%((match (make-pong) ((pong?) 'got-pong) (else 'nope))))).should eq("got-pong")
  end

  it "tries clauses in order and falls through to else" do
    w(define_types(%((match "not a record" ((ping? from) 'ping) ((pong?) 'pong) (else 'other))))).should eq("other")
  end

  it "evaluates the matched expression exactly once" do
    w(define_types(<<-SCHEME)).should eq("1")
      (define calls 0)
      (define (make-and-count)
        (set! calls (+ calls 1))
        (make-pong))
      (match (make-and-count) ((pong?) 'ok))
      calls
      SCHEME
  end

  it "raises when no clause matches and there's no else" do
    expect_raises(Creme::SchemeError) { run(define_types(%((match (make-ping 1) ((pong?) 'x))))) }
  end

  it "record-fields is re-exported for callers that want raw positional access" do
    w(define_types(%((record-fields (make-ping 7))))).should eq("(7)")
  end
end
