require "../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (creme extra)) #{src}").write_string
end

describe "extra module" do
  it "times runs its body n times purely for side effects" do
    w(<<-SCHEME).should eq("3")
      (define count 0)
      (times 3 (set! count (+ count 1)))
      count
      SCHEME
  end

  it "times with n = 0 runs the body zero times" do
    w(<<-SCHEME).should eq("0")
      (define count 0)
      (times 0 (set! count (+ count 1)))
      count
      SCHEME
  end
end
