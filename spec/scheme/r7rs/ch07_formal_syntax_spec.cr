require "../../spec_helper"

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "R7RS §7.1 Formal syntax" do
  it "read parses '(+ 2 6)' as data (a 3-element list), distinct from evaluating it as an expression (8)" do
    w(<<-SCM).should eq("((+ 2 6) 8)")
      (import (scheme read))
      (define p (open-input-string "(+ 2 6)"))
      (list (read p) (+ 2 6))
    SCM
  end

  pending "the formal <body> grammar (§7.1.1) requires all <definition>s to precede every <expression> within a body — this implementation allows a definition to follow an expression in a body without error, e.g. (let () (display \"x\") (define y 1) y) succeeds here instead of being rejected"
end

describe "R7RS §7.2 Formal semantics (tail contexts)" do
  # The tail-context positions enumerated by the formal semantics (if/cond/case/and/or/when/unless/
  # let-family/begin/do bodies) are already covered by executable proper-tail-recursion tests in
  # ch03_basic_concepts_spec.cr §3.5, derived from this same grammar.
end
