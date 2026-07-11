require "../spec_helper"

describe LISP::LispError do
  it "is an Exception" do
    LISP::LispError.new("boom").should be_a(Exception)
  end

  it "carries a message" do
    LISP::LispError.new("boom").message.should eq("boom")
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
