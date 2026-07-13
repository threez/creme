require "./spec_helper"

describe Scheme do
  it "has a version" do
    Scheme::VERSION.should be_a(String)
    Scheme::VERSION.should_not be_empty
  end
end
