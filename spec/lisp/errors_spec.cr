require "../spec_helper"

describe LISP::LispError do
  it "is an Exception" do
    LISP::LispError.new("boom").should be_a(Exception)
  end

  it "carries a message" do
    LISP::LispError.new("boom").message.should eq("boom")
  end

  it "has empty frames and no position when no interpreter is currently evaluating" do
    ex = LISP::LispError.new("boom")
    ex.frames.should eq([] of LISP::Frame)
    ex.pos.should be_nil
  end
end

describe LISP::LispParseError do
  it "is a LispError" do
    LISP::LispParseError.new("bad syntax").should be_a(LISP::LispError)
  end

  it "carries a message" do
    LISP::LispParseError.new("bad syntax").message.should eq("bad syntax")
  end
end

describe LISP::LispIncompleteError do
  it "is a LispParseError" do
    LISP::LispIncompleteError.new("eof").should be_a(LISP::LispParseError)
  end

  it "is a LispError" do
    LISP::LispIncompleteError.new("eof").should be_a(LISP::LispError)
  end
end

describe LISP::LispRuntimeError do
  it "is a LispError" do
    LISP::LispRuntimeError.new("runtime issue").should be_a(LISP::LispError)
  end

  it "carries a message" do
    LISP::LispRuntimeError.new("runtime issue").message.should eq("runtime issue")
  end
end

describe LISP::LispUserError do
  it "is a LispRuntimeError" do
    LISP::LispUserError.new("user raised").should be_a(LISP::LispRuntimeError)
  end

  it "is a LispError" do
    LISP::LispUserError.new("user raised").should be_a(LISP::LispError)
  end
end

describe LISP::LispExecutionLimitError do
  it "is a LispRuntimeError" do
    LISP::LispExecutionLimitError.new("limit hit").should be_a(LISP::LispRuntimeError)
  end

  it "is a LispError" do
    LISP::LispExecutionLimitError.new("limit hit").should be_a(LISP::LispError)
  end

  it "carries a message" do
    LISP::LispExecutionLimitError.new("limit hit").message.should eq("limit hit")
  end
end

describe LISP::LispExit do
  it "is an Exception" do
    LISP::LispExit.new.should be_a(Exception)
  end

  it "is not a LispError" do
    LISP::LispExit.new.should_not be_a(LISP::LispError)
  end

  it "defaults to code 0" do
    LISP::LispExit.new.code.should eq(0)
  end

  it "carries the given code" do
    LISP::LispExit.new(2).code.should eq(2)
  end

  it "carries a descriptive message" do
    LISP::LispExit.new(3).message.should eq("exit(3)")
  end
end
