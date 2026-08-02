require "../spec_helper"

describe Creme::SchemeError do
  it "is an Exception" do
    Creme::SchemeError.new("boom").should be_a(Exception)
  end

  it "carries a message" do
    Creme::SchemeError.new("boom").message.should eq("boom")
  end

  it "has empty frames and no position when no interpreter is currently evaluating" do
    ex = Creme::SchemeError.new("boom")
    ex.frames.should eq([] of Creme::Frame)
    ex.pos.should be_nil
  end

  it "has no payload by default" do
    Creme::SchemeError.new("boom").payload.should be_nil
  end

  it "carries an explicitly attached payload" do
    ex = Creme::SchemeError.new("boom")
    condition = Creme::SchemeRecord.new(Creme::CONDITION_TYPE, [Creme::SchemeStr.new("boom"), Creme::NIL] of Creme::SchemeValue)
    ex.payload = condition
    ex.payload.should eq(condition)
  end
end

describe Creme::SchemeParseError do
  it "is a SchemeError" do
    Creme::SchemeParseError.new("bad syntax").should be_a(Creme::SchemeError)
  end

  it "carries a message" do
    Creme::SchemeParseError.new("bad syntax").message.should eq("bad syntax")
  end
end

describe Creme::SchemeIncompleteError do
  it "is a SchemeParseError" do
    Creme::SchemeIncompleteError.new("eof").should be_a(Creme::SchemeParseError)
  end

  it "is a SchemeError" do
    Creme::SchemeIncompleteError.new("eof").should be_a(Creme::SchemeError)
  end
end

describe Creme::SchemeRuntimeError do
  it "is a SchemeError" do
    Creme::SchemeRuntimeError.new("runtime issue").should be_a(Creme::SchemeError)
  end

  it "carries a message" do
    Creme::SchemeRuntimeError.new("runtime issue").message.should eq("runtime issue")
  end
end

describe Creme::SchemeUserError do
  it "is a SchemeRuntimeError" do
    Creme::SchemeUserError.new("user raised").should be_a(Creme::SchemeRuntimeError)
  end

  it "is a SchemeError" do
    Creme::SchemeUserError.new("user raised").should be_a(Creme::SchemeError)
  end
end

describe Creme::SchemeExecutionLimitError do
  it "is a SchemeRuntimeError" do
    Creme::SchemeExecutionLimitError.new("limit hit").should be_a(Creme::SchemeRuntimeError)
  end

  it "is a SchemeError" do
    Creme::SchemeExecutionLimitError.new("limit hit").should be_a(Creme::SchemeError)
  end

  it "carries a message" do
    Creme::SchemeExecutionLimitError.new("limit hit").message.should eq("limit hit")
  end
end

describe Creme::SchemeExit do
  it "is an Exception" do
    Creme::SchemeExit.new.should be_a(Exception)
  end

  it "is not a SchemeError" do
    Creme::SchemeExit.new.should_not be_a(Creme::SchemeError)
  end

  it "defaults to code 0" do
    Creme::SchemeExit.new.code.should eq(0)
  end

  it "carries the given code" do
    Creme::SchemeExit.new(2).code.should eq(2)
  end

  it "carries a descriptive message" do
    Creme::SchemeExit.new(3).message.should eq("exit(3)")
  end
end

describe Creme::ContinuationInvoked do
  it "is an Exception" do
    Creme::ContinuationInvoked.new(1_i64, Creme::NIL).should be_a(Exception)
  end

  it "is not a SchemeError" do
    Creme::ContinuationInvoked.new(1_i64, Creme::NIL).should_not be_a(Creme::SchemeError)
  end

  it "carries the tag and value it was raised with" do
    ex = Creme::ContinuationInvoked.new(7_i64, Creme::SchemeInt.new(42_i64))
    ex.tag.should eq(7_i64)
    ex.value.write_string.should eq("42")
  end
end
