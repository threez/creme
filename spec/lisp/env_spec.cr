require "../spec_helper"

describe LISP::Env do
  it "defines and retrieves a variable" do
    env = LISP::Env.new
    env.define("x", LISP::LispInt.new(1_i64))
    env.get("x").as(LISP::LispInt).value.should eq(1_i64)
  end

  it "raises LispRuntimeError for an unbound variable" do
    env = LISP::Env.new
    expect_raises(LISP::LispRuntimeError, /unbound variable: y/) do
      env.get("y")
    end
  end

  it "looks up variables through the parent chain" do
    parent = LISP::Env.new
    parent.define("x", LISP::LispInt.new(5_i64))
    child = LISP::Env.new(parent)
    child.get("x").as(LISP::LispInt).value.should eq(5_i64)
  end

  it "shadows a parent binding with a local one" do
    parent = LISP::Env.new
    parent.define("x", LISP::LispInt.new(5_i64))
    child = LISP::Env.new(parent)
    child.define("x", LISP::LispInt.new(9_i64))
    child.get("x").as(LISP::LispInt).value.should eq(9_i64)
    parent.get("x").as(LISP::LispInt).value.should eq(5_i64)
  end

  it "set! updates an existing local binding" do
    env = LISP::Env.new
    env.define("x", LISP::LispInt.new(1_i64))
    env.set!("x", LISP::LispInt.new(2_i64))
    env.get("x").as(LISP::LispInt).value.should eq(2_i64)
  end

  it "set! walks up to update a parent binding" do
    parent = LISP::Env.new
    parent.define("x", LISP::LispInt.new(1_i64))
    child = LISP::Env.new(parent)
    child.set!("x", LISP::LispInt.new(42_i64))
    parent.get("x").as(LISP::LispInt).value.should eq(42_i64)
  end

  it "set! raises LispRuntimeError for an unbound variable" do
    env = LISP::Env.new
    expect_raises(LISP::LispRuntimeError, /set!: unbound variable: z/) do
      env.set!("z", LISP::LispInt.new(1_i64))
    end
  end

  it "exposes its parent via the parent getter" do
    parent = LISP::Env.new
    child = LISP::Env.new(parent)
    child.parent.should be(parent)
    parent.parent.should be_nil
  end

  it "define_fn registers a callable Builtin" do
    env = LISP::Env.new
    env.define_fn("double", 1, 1) { |args| LISP::LispInt.new(args[0].as(LISP::LispInt).value * 2) }
    fn = env.get("double")
    fn.should be_a(LISP::Builtin)
    fn.as(LISP::Builtin).name.should eq("double")
    fn.as(LISP::Builtin).fn.call([LISP::LispInt.new(21_i64)] of LISP::LispValue)
      .as(LISP::LispInt).value.should eq(42_i64)
  end
end
