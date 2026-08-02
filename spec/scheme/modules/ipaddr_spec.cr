require "../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (scheme base) (creme ipaddr)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (scheme base) (creme ipaddr)) #{src}")
end

describe "ipaddr module" do
  it "round-trips a bare IPv4 host address" do
    w(%((ipaddr->string (make-ipaddr "192.168.1.1")))).should eq(%("192.168.1.1"))
  end

  it "round-trips a bare IPv6 address, compressing the longest zero run" do
    w(%((ipaddr->string (make-ipaddr "::1")))).should eq(%("::1"))
    w(%((ipaddr->string (make-ipaddr "::")))).should eq(%("::"))
    w(%((ipaddr->string (make-ipaddr "fe80::")))).should eq(%("fe80::"))
    w(%((ipaddr->string (make-ipaddr "2001:0db8:0000:0000:0000:0000:0000:0001")))).should eq(%("2001:db8::1"))
  end

  it "compresses the leftmost run on a length tie (RFC 5952)" do
    w(%((ipaddr->string (make-ipaddr "2001:0:0:1:0:0:1:1")))).should eq(%("2001::1:0:0:1:1"))
  end

  it "auto-detects family from ':' vs '.'" do
    w(%((ipv4-address? (make-ipaddr "1.2.3.4")))).should eq("#t")
    w(%((ipv6-address? (make-ipaddr "1.2.3.4")))).should eq("#f")
    w(%((ipv6-address? (make-ipaddr "::1")))).should eq("#t")
  end

  it "parses a CIDR prefix, defaulting to the full address width otherwise" do
    w(%((ipaddr-prefix (make-ipaddr "10.0.0.0/8")))).should eq("8")
    w(%((ipaddr-prefix (make-ipaddr "10.0.0.1")))).should eq("32")
    w(%((ipaddr-prefix (make-ipaddr "::1")))).should eq("128")
  end

  it "computes network/broadcast/netmask/hostmask for IPv4" do
    w(%((ipaddr->string (ipaddr-network (make-ipaddr "192.168.1.55/24"))))).should eq(%("192.168.1.0"))
    w(%((ipaddr->string (ipaddr-broadcast (make-ipaddr "192.168.1.55/24"))))).should eq(%("192.168.1.255"))
    w(%((ipaddr->string (ipaddr-netmask (make-ipaddr "192.168.1.55/24"))))).should eq(%("255.255.255.0"))
    w(%((ipaddr->string (ipaddr-hostmask (make-ipaddr "192.168.1.55/24"))))).should eq(%("0.0.0.255"))
  end

  it "computes network/netmask for IPv6 across a group boundary and mid-group" do
    w(%((ipaddr->string (ipaddr-network (make-ipaddr "2001:db8:abcd:1234::1/32"))))).should eq(%("2001:db8::"))
    w(%((ipaddr->string (ipaddr-netmask (make-ipaddr "2001:db8::1/64"))))).should eq(%("ffff:ffff:ffff:ffff::"))
    w(%((ipaddr->string (ipaddr-network (make-ipaddr "10.1.2.3/12"))))).should eq(%("10.0.0.0"))
  end

  it "ipaddr-include? checks CIDR containment, both bare hosts and subnets" do
    w(%((ipaddr-include? (make-ipaddr "10.0.0.0/8") (make-ipaddr "10.1.2.3")))).should eq("#t")
    w(%((ipaddr-include? (make-ipaddr "10.0.0.0/8") (make-ipaddr "11.0.0.0")))).should eq("#f")
    w(%((ipaddr-include? (make-ipaddr "10.0.0.0/8") (make-ipaddr "10.1.0.0/16")))).should eq("#t")
    w(%((ipaddr-include? (make-ipaddr "10.0.0.0/16") (make-ipaddr "10.1.0.0/8")))).should eq("#f")
    w(%((ipaddr-include? (make-ipaddr "::/0") (make-ipaddr "ffff::1")))).should eq("#t")
  end

  it "raises when ipaddr-include? is given mismatched families" do
    expect_raises(Scheme::SchemeError) { run(%((ipaddr-include? (make-ipaddr "10.0.0.0/8") (make-ipaddr "::1")))) }
  end

  it "ipaddr=? compares address only, ignoring prefix; ipaddr<? orders by address" do
    w(%((ipaddr=? (make-ipaddr "192.168.1.1") (make-ipaddr "192.168.1.1/24")))).should eq("#t")
    w(%((ipaddr=? (make-ipaddr "192.168.1.1") (make-ipaddr "192.168.1.2")))).should eq("#f")
    w(%((ipaddr<? (make-ipaddr "192.168.1.1") (make-ipaddr "192.168.1.2")))).should eq("#t")
  end

  it "raises when ipaddr<? is given mismatched families" do
    expect_raises(Scheme::SchemeError) { run(%((ipaddr<? (make-ipaddr "192.168.1.1") (make-ipaddr "::1")))) }
  end

  it "ipaddr-succ/ipaddr-pred step the address by one, carrying/borrowing across groups" do
    w(%((ipaddr->string (ipaddr-succ (make-ipaddr "192.168.1.255"))))).should eq(%("192.168.2.0"))
    w(%((ipaddr->string (ipaddr-pred (make-ipaddr "192.168.1.0"))))).should eq(%("192.168.0.255"))
    w(%((ipaddr->string (ipaddr-succ (make-ipaddr "ffff:ffff:ffff:ffff:ffff:ffff:ffff:fffe")))))
      .should eq(%("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"))
  end

  it "raises rather than overflowing/underflowing past the address space" do
    expect_raises(Scheme::SchemeError) { run(%((ipaddr-succ (make-ipaddr "255.255.255.255")))) }
    expect_raises(Scheme::SchemeError) { run(%((ipaddr-pred (make-ipaddr "0.0.0.0")))) }
  end

  it "ipaddr->groups/groups->ipaddr round-trip the MSB-first per-group representation" do
    w(%((ipaddr->groups (make-ipaddr "10.0.0.1")))).should eq("(10 0 0 1)")
    w(%((ipaddr->string (groups->ipaddr 'ipv4 '(10 0 0 1))))).should eq(%("10.0.0.1"))
  end

  it "raises on malformed input rather than silently truncating/wrapping" do
    expect_raises(Scheme::SchemeError) { run(%((make-ipaddr "192.168.1.256"))) }
    expect_raises(Scheme::SchemeError) { run(%((make-ipaddr "1.2.3"))) }
    expect_raises(Scheme::SchemeError) { run(%((make-ipaddr "1::2::3"))) }
    expect_raises(Scheme::SchemeError) { run(%((make-ipaddr "10.0.0.0/33"))) }
  end

  it "distinguishes ipaddr? from other values" do
    w(%((list (ipaddr? (make-ipaddr "10.0.0.1")) (ipaddr? "10.0.0.1")))).should eq("(#t #f)")
  end
end
