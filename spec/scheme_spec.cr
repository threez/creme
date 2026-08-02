require "./spec_helper"

describe Creme do
  it "has a version" do
    Creme::VERSION.should be_a(String)
    Creme::VERSION.should_not be_empty
  end
end
