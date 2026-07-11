require "./spec_helper"

describe LISP do
  it "has a version" do
    LISP::VERSION.should be_a(String)
    LISP::VERSION.should_not be_empty
  end
end
