require "../spec_helper"

describe Scheme::Env do
  it "defines and retrieves a variable" do
    env = Scheme::Env.new
    env.define("x", Scheme::SchemeInt.new(1_i64))
    env.get("x").as(Scheme::SchemeInt).value.should eq(1_i64)
  end

  it "raises SchemeRuntimeError for an unbound variable" do
    env = Scheme::Env.new
    expect_raises(Scheme::SchemeRuntimeError, /unbound variable: y/) do
      env.get("y")
    end
  end

  it "looks up variables through the parent chain" do
    parent = Scheme::Env.new
    parent.define("x", Scheme::SchemeInt.new(5_i64))
    child = Scheme::Env.new(parent)
    child.get("x").as(Scheme::SchemeInt).value.should eq(5_i64)
  end

  it "shadows a parent binding with a local one" do
    parent = Scheme::Env.new
    parent.define("x", Scheme::SchemeInt.new(5_i64))
    child = Scheme::Env.new(parent)
    child.define("x", Scheme::SchemeInt.new(9_i64))
    child.get("x").as(Scheme::SchemeInt).value.should eq(9_i64)
    parent.get("x").as(Scheme::SchemeInt).value.should eq(5_i64)
  end

  it "set! updates an existing local binding" do
    env = Scheme::Env.new
    env.define("x", Scheme::SchemeInt.new(1_i64))
    env.set!("x", Scheme::SchemeInt.new(2_i64))
    env.get("x").as(Scheme::SchemeInt).value.should eq(2_i64)
  end

  it "set! walks up to update a parent binding" do
    parent = Scheme::Env.new
    parent.define("x", Scheme::SchemeInt.new(1_i64))
    child = Scheme::Env.new(parent)
    child.set!("x", Scheme::SchemeInt.new(42_i64))
    parent.get("x").as(Scheme::SchemeInt).value.should eq(42_i64)
  end

  it "set! raises SchemeRuntimeError for an unbound variable" do
    env = Scheme::Env.new
    expect_raises(Scheme::SchemeRuntimeError, /set!: unbound variable: z/) do
      env.set!("z", Scheme::SchemeInt.new(1_i64))
    end
  end

  it "exposes its parent via the parent getter" do
    parent = Scheme::Env.new
    child = Scheme::Env.new(parent)
    child.parent.should be(parent)
    parent.parent.should be_nil
  end

  it "define_fn registers a callable Builtin" do
    env = Scheme::Env.new
    env.define_fn("double", 1, 1) { |args| Scheme::SchemeInt.new(args[0].as(Scheme::SchemeInt).value * 2) }
    fn = env.get("double")
    fn.should be_a(Scheme::Builtin)
    fn.as(Scheme::Builtin).name.should eq("double")
    fn.as(Scheme::Builtin).fn.call([Scheme::SchemeInt.new(21_i64)] of Scheme::SchemeValue)
      .as(Scheme::SchemeInt).value.should eq(42_i64)
  end
end
