require "../../spec_helper"

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "guard" do
  it "catches an error and evaluates the matching clause" do
    w(%[(guard (e (#t 'caught)) (error "boom"))]).should eq("caught")
  end

  it "binds the condition to the guard variable" do
    w(%[(guard (e (#t (error-object-message e))) (error "boom"))]).should eq(%("boom"))
  end

  it "exposes structured irritants via error-object-irritants" do
    w(%[(guard (e (#t (error-object-irritants e))) (error "boom" 1 2))]).should eq("(1 2)")
  end

  it "supports an else clause" do
    w(%[(guard (e (else 'fallback)) (error "boom"))]).should eq("fallback")
  end

  it "supports multiple clauses, matching the first truthy test" do
    src = <<-SCHEME
      (guard (e
               ((string? (error-object-message e)) 'string-msg)
               (else 'other))
        (error "boom"))
      SCHEME
    w(src).should eq("string-msg")
  end

  it "re-raises when no clause matches" do
    expect_raises(Creme::SchemeUserError, /boom/) do
      run(%[(guard (e (#f 'never)) (error "boom"))])
    end
  end

  it "returns the body's value when no error is raised" do
    w("(guard (e (#t 'caught)) 42)").should eq("42")
  end

  it "catches errors raised by builtins/special forms, not just (error ...)" do
    w("(guard (e (#t 'caught)) (car '()))").should eq("caught")
  end

  it "synthesizes a fallback condition (via error-object-message) for non-error? errors" do
    w("(guard (e (#t (error-object-message e))) (car '()))").should match(/car/)
  end

  it "error-object? is true for a caught condition and false otherwise" do
    w("(guard (e (#t (error-object? e))) (error \"boom\"))").should eq("#t")
    w("(error-object? 5)").should eq("#f")
  end

  it "does not catch (exit ...): it keeps propagating" do
    expect_raises(Creme::SchemeExit) do
      run("(import (scheme process-context)) (guard (e (#t 'caught)) (exit 1))")
    end
  end

  it "does not catch a max_eval_depth exceeded error" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"], max_eval_depth: 10)
    expect_raises(Creme::SchemeExecutionLimitError, /recursion depth exceeded/) do
      Creme.run_source(interp, "(define (f n) (+ 1 (f (+ n 1)))) (guard (e (#t 'caught)) (f 0))")
    end
  end

  it "catches a max_eval_depth exceeded error when guard_catches_execution_limit_errors is true" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"], max_eval_depth: 10, guard_catches_execution_limit_errors: true)
    result = Creme.run_source(interp, "(define (f n) (+ 1 (f (+ n 1)))) (guard (e (#t 'caught)) (f 0))")
    result.write_string.should eq("caught")
  end

  it "catches (exit ...) when guard_catches_exit is true" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"], guard_catches_exit: true)
    result = Creme.run_source(interp, "(import (scheme process-context)) (guard (e (#t 'caught)) (exit 1))")
    result.write_string.should eq("caught")
  end

  it "still re-raises (exit ...) as SchemeExit when guard_catches_exit is true but no clause matches" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"], guard_catches_exit: true)
    expect_raises(Creme::SchemeExit) do
      Creme.run_source(interp, "(import (scheme process-context)) (guard (e (#f 'never)) (exit 1))")
    end
  end

  it "supports nested guard, re-raising from inner to outer when the inner clause doesn't match" do
    src = <<-SCHEME
      (guard (outer (#t (list 'outer (error-object-message outer))))
        (guard (inner (#f 'unreachable))
          (error "inner-boom")))
      SCHEME
    w(src).should eq(%((outer "inner-boom")))
  end

  it "an inner guard's matching clause shadows the outer guard" do
    src = <<-SCHEME
      (guard (outer (#t 'unreachable))
        (guard (inner (#t 'caught-by-inner))
          (error "inner-boom")))
      SCHEME
    w(src).should eq("caught-by-inner")
  end

  it "raises on malformed input" do
    expect_raises(Creme::SchemeRuntimeError, /guard: malformed/) do
      run("(guard)")
    end
  end

  it "binds the raw raised object for (raise obj), not a synthesized error-object condition" do
    w(%[(guard (e (#t e)) (raise 'my-symbol))]).should eq("my-symbol")
    w(%[(guard (e (#t e)) (raise '(1 2 3)))]).should eq("(1 2 3)")
    w(%[(guard (e (#t (error-object? e))) (raise 'my-symbol))]).should eq("#f")
  end
end
