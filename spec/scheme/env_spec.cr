require "../spec_helper"

describe Creme::Env do
  it "defines and retrieves a variable" do
    env = Creme::Env.new
    env.define("x", Creme::SchemeInt.new(1_i64))
    env.get("x").as(Creme::SchemeInt).value.should eq(1_i64)
  end

  it "raises SchemeRuntimeError for an unbound variable" do
    env = Creme::Env.new
    expect_raises(Creme::SchemeRuntimeError, /unbound variable: y/) do
      env.get("y")
    end
  end

  it "looks up variables through the parent chain" do
    parent = Creme::Env.new
    parent.define("x", Creme::SchemeInt.new(5_i64))
    child = Creme::Env.new(parent)
    child.get("x").as(Creme::SchemeInt).value.should eq(5_i64)
  end

  it "shadows a parent binding with a local one" do
    parent = Creme::Env.new
    parent.define("x", Creme::SchemeInt.new(5_i64))
    child = Creme::Env.new(parent)
    child.define("x", Creme::SchemeInt.new(9_i64))
    child.get("x").as(Creme::SchemeInt).value.should eq(9_i64)
    parent.get("x").as(Creme::SchemeInt).value.should eq(5_i64)
  end

  it "set! updates an existing local binding" do
    env = Creme::Env.new
    env.define("x", Creme::SchemeInt.new(1_i64))
    env.set!("x", Creme::SchemeInt.new(2_i64))
    env.get("x").as(Creme::SchemeInt).value.should eq(2_i64)
  end

  it "set! walks up to update a parent binding" do
    parent = Creme::Env.new
    parent.define("x", Creme::SchemeInt.new(1_i64))
    child = Creme::Env.new(parent)
    child.set!("x", Creme::SchemeInt.new(42_i64))
    parent.get("x").as(Creme::SchemeInt).value.should eq(42_i64)
  end

  it "set! raises SchemeRuntimeError for an unbound variable" do
    env = Creme::Env.new
    expect_raises(Creme::SchemeRuntimeError, /set!: unbound variable: z/) do
      env.set!("z", Creme::SchemeInt.new(1_i64))
    end
  end

  it "exposes its parent via the parent getter" do
    parent = Creme::Env.new
    child = Creme::Env.new(parent)
    child.parent.should be(parent)
    parent.parent.should be_nil
  end

  it "define_fn registers a callable Builtin" do
    env = Creme::Env.new
    env.define_fn("double", 1, 1) { |args| Creme::SchemeInt.new(args[0].as(Creme::SchemeInt).value * 2) }
    fn = env.get("double")
    fn.should be_a(Creme::Builtin)
    fn.as(Creme::Builtin).name.should eq("double")
    fn.as(Creme::Builtin).fn.call([Creme::SchemeInt.new(21_i64)] of Creme::SchemeValue)
      .as(Creme::SchemeInt).value.should eq(42_i64)
  end
end
