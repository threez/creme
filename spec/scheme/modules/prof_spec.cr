require "../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (creme prof)) #{src}").write_string
end

describe "prof frontend module" do
  it "re-exports both prof-native and prof-vm bindings" do
    w(<<-SCM).should eq("#t")
      (define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
      (and (profile-scheme-report? (profile-scheme (lambda () (fib 20)) 50))
           (profile-report? (profile (lambda () (fib 20)) 5)))
    SCM
  end
end
