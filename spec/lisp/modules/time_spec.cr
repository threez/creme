require "../../spec_helper"

private def w(src : String) : String
  interp = LISP::Interpreter.new
  LISP.run_source(interp, "(require 'time) #{src}").write_string
end

describe "time module" do
  it "formats and parses round-trip" do
    w(%((time:format (time:parse "2026-07-10 12:30:00" "%Y-%m-%d %H:%M:%S") "%Y-%m-%d %H:%M:%S")))
      .should eq(%("2026-07-10 12:30:00"))
  end

  it "extracts date/time components" do
    epoch = "(time:parse \"2026-07-10 12:30:45\" \"%Y-%m-%d %H:%M:%S\")"
    w("(time:year #{epoch})").should eq("2026")
    w("(time:month #{epoch})").should eq("7")
    w("(time:day #{epoch})").should eq("10")
    w("(time:hour #{epoch})").should eq("12")
    w("(time:minute #{epoch})").should eq("30")
    w("(time:second #{epoch})").should eq("45")
  end

  it "adds seconds and diffs" do
    w("(time:add-seconds 1000.0 5.0)").should eq("1005.0")
    w("(time:diff 1005.0 1000.0)").should eq("5.0")
  end

  it "now returns a plausible unix epoch float" do
    interp = LISP::Interpreter.new
    result = LISP.run_source(interp, "(require 'time) (time:now)")
    result.should be_a(LISP::LispFloat)
    result.as(LISP::LispFloat).value.should be > 1_700_000_000.0
  end
end
