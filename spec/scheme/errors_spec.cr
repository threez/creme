require "../spec_helper"

describe Scheme::SchemeError do
  it "is an Exception" do
    Scheme::SchemeError.new("boom").should be_a(Exception)
  end

  it "carries a message" do
    Scheme::SchemeError.new("boom").message.should eq("boom")
  end

  it "has empty frames and no position when no interpreter is currently evaluating" do
    ex = Scheme::SchemeError.new("boom")
    ex.frames.should eq([] of Scheme::Frame)
    ex.pos.should be_nil
  end

  it "has no payload by default" do
    Scheme::SchemeError.new("boom").payload.should be_nil
  end

  it "carries an explicitly attached payload" do
    ex = Scheme::SchemeError.new("boom")
    condition = Scheme::SchemeRecord.new(Scheme::CONDITION_TYPE, [Scheme::SchemeStr.new("boom"), Scheme::NIL] of Scheme::SchemeValue)
    ex.payload = condition
    ex.payload.should eq(condition)
  end
end

describe Scheme::SchemeParseError do
  it "is a SchemeError" do
    Scheme::SchemeParseError.new("bad syntax").should be_a(Scheme::SchemeError)
  end

  it "carries a message" do
    Scheme::SchemeParseError.new("bad syntax").message.should eq("bad syntax")
  end
end

describe Scheme::SchemeIncompleteError do
  it "is a SchemeParseError" do
    Scheme::SchemeIncompleteError.new("eof").should be_a(Scheme::SchemeParseError)
  end

  it "is a SchemeError" do
    Scheme::SchemeIncompleteError.new("eof").should be_a(Scheme::SchemeError)
  end
end

describe Scheme::SchemeRuntimeError do
  it "is a SchemeError" do
    Scheme::SchemeRuntimeError.new("runtime issue").should be_a(Scheme::SchemeError)
  end

  it "carries a message" do
    Scheme::SchemeRuntimeError.new("runtime issue").message.should eq("runtime issue")
  end
end

describe Scheme::SchemeUserError do
  it "is a SchemeRuntimeError" do
    Scheme::SchemeUserError.new("user raised").should be_a(Scheme::SchemeRuntimeError)
  end

  it "is a SchemeError" do
    Scheme::SchemeUserError.new("user raised").should be_a(Scheme::SchemeError)
  end
end

describe Scheme::SchemeExecutionLimitError do
  it "is a SchemeRuntimeError" do
    Scheme::SchemeExecutionLimitError.new("limit hit").should be_a(Scheme::SchemeRuntimeError)
  end

  it "is a SchemeError" do
    Scheme::SchemeExecutionLimitError.new("limit hit").should be_a(Scheme::SchemeError)
  end

  it "carries a message" do
    Scheme::SchemeExecutionLimitError.new("limit hit").message.should eq("limit hit")
  end
end

describe Scheme::SchemeExit do
  it "is an Exception" do
    Scheme::SchemeExit.new.should be_a(Exception)
  end

  it "is not a SchemeError" do
    Scheme::SchemeExit.new.should_not be_a(Scheme::SchemeError)
  end

  it "defaults to code 0" do
    Scheme::SchemeExit.new.code.should eq(0)
  end

  it "carries the given code" do
    Scheme::SchemeExit.new(2).code.should eq(2)
  end

  it "carries a descriptive message" do
    Scheme::SchemeExit.new(3).message.should eq("exit(3)")
  end
end

describe Scheme::ContinuationInvoked do
  it "is an Exception" do
    Scheme::ContinuationInvoked.new(1_i64, Scheme::NIL).should be_a(Exception)
  end

  it "is not a SchemeError" do
    Scheme::ContinuationInvoked.new(1_i64, Scheme::NIL).should_not be_a(Scheme::SchemeError)
  end

  it "carries the tag and value it was raised with" do
    ex = Scheme::ContinuationInvoked.new(7_i64, Scheme::SchemeInt.new(42_i64))
    ex.tag.should eq(7_i64)
    ex.value.write_string.should eq("42")
  end
end
