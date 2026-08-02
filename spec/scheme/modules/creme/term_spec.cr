require "../../../spec_helper"

# Term.read_key_event only applies its escape-sequence follow-up timeout to
# an IO::FileDescriptor (see Term.read_byte_timeout's io.as?(IO::FileDescriptor)
# guard) -- a plain IO::Memory always looks like "no more bytes yet" and every
# escape sequence would bail out early as a bare Esc. Route the bytes through
# a real pipe so the reading side is a genuine file descriptor, matching how
# STDIN is read in production -- same approach as lib/tui/spec/core/keys_spec.cr's
# own read_from helper, which this ports the covered cases from.
private def read_from(bytes : Bytes) : Scheme::SchemeValue
  reader, writer = IO.pipe
  writer.write(bytes)
  writer.close
  Scheme::Builtins::Term.read_key_event(reader)
ensure
  reader.try &.close
end

private def kind_of(v : Scheme::SchemeValue) : String
  alist = v.as(Scheme::Cons)
  pair = alist.car.as(Scheme::Cons)
  pair.cdr.as(Scheme::SchemeStr).value
end

describe Scheme::Builtins::Term do
  describe ".read_key_event" do
    it "parses a plain character" do
      kind_of(read_from("x".to_slice)).should eq("char")
    end

    it "parses Ctrl-A" do
      kind_of(read_from("".to_slice)).should eq("ctrl-a")
    end

    it "parses Ctrl-E" do
      kind_of(read_from("".to_slice)).should eq("ctrl-e")
    end

    it "still parses Ctrl-C and Ctrl-D (regression check alongside the new Ctrl-A/E cases)" do
      kind_of(read_from("".to_slice)).should eq("ctrl-c")
      kind_of(read_from("".to_slice)).should eq("ctrl-d")
    end

    it "parses Ctrl-Right and Alt-Right (CSI form) as word-right" do
      kind_of(read_from("\e[1;5C".to_slice)).should eq("word-right")
      kind_of(read_from("\e[1;3C".to_slice)).should eq("word-right")
    end

    it "parses Ctrl-Left and Alt-Left (CSI form) as word-left" do
      kind_of(read_from("\e[1;5D".to_slice)).should eq("word-left")
      kind_of(read_from("\e[1;3D".to_slice)).should eq("word-left")
    end

    it "parses Alt-Right/Alt-Left (bare-ESC form, ESC f / ESC b) as word-right/word-left" do
      kind_of(read_from("\ef".to_slice)).should eq("word-right")
      kind_of(read_from("\eb".to_slice)).should eq("word-left")
    end

    it "still parses plain arrow keys and Home/End (regression check)" do
      kind_of(read_from("\e[A".to_slice)).should eq("up")
      kind_of(read_from("\e[D".to_slice)).should eq("left")
      kind_of(read_from("\e[H".to_slice)).should eq("home")
      kind_of(read_from("\e[F".to_slice)).should eq("end")
    end
  end
end
