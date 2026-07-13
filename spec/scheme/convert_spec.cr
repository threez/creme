require "../spec_helper"

private def i(n : Int64) : Scheme::SchemeValue
  Scheme::SchemeInt.new(n)
end

describe "Scheme.to_scheme" do
  it "converts nil to NIL" do
    Scheme.to_scheme(nil).should be(Scheme::NIL)
  end

  it "converts a Bool" do
    Scheme.to_scheme(true).should be(Scheme::TRUE)
    Scheme.to_scheme(false).should be(Scheme::FALSE)
  end

  it "converts an Int" do
    Scheme.to_scheme(42).as(Scheme::SchemeInt).value.should eq(42_i64)
  end

  it "converts a Float" do
    Scheme.to_scheme(1.5).as(Scheme::SchemeFloat).value.should eq(1.5)
  end

  it "converts a String" do
    Scheme.to_scheme("hi").as(Scheme::SchemeStr).value.should eq("hi")
  end

  it "converts an Array to a SchemeVector, recursively" do
    vec = Scheme.to_scheme([1, "a", true]).as(Scheme::SchemeVector)
    vec.value[0].as(Scheme::SchemeInt).value.should eq(1_i64)
    vec.value[1].as(Scheme::SchemeStr).value.should eq("a")
    vec.value[2].should be(Scheme::TRUE)
  end

  it "converts a Hash to an alist of (SchemeStr . value), recursively" do
    pairs = Scheme.list_to_a(Scheme.to_scheme({"name" => "Ada", "age" => 36}))
    pairs.size.should eq(2)
    first = pairs[0].as(Scheme::Cons)
    first.car.as(Scheme::SchemeStr).value.should eq("name")
    first.cdr.as(Scheme::SchemeStr).value.should eq("Ada")
    second = pairs[1].as(Scheme::Cons)
    second.car.as(Scheme::SchemeStr).value.should eq("age")
    second.cdr.as(Scheme::SchemeInt).value.should eq(36_i64)
  end

  it "converts a JSON::Any by delegating to its raw value" do
    any = JSON.parse(%({"a": 1, "b": [true, null]}))
    result = Scheme.from_scheme(Scheme.to_scheme(any)).as(Hash(String, Scheme::Convertible))
    result["a"].should eq(1_i64)
    result["b"].should eq([true, nil])
  end

  it "passes an already-built SchemeValue through unchanged (identity)" do
    v = Scheme::SchemeInt.new(9_i64)
    Scheme.to_scheme(v).should be(v)
  end

  it "converts a Time to an epoch-second SchemeFloat" do
    t = Time.utc(2026, 1, 1)
    Scheme.to_scheme(t).as(Scheme::SchemeFloat).value.should eq(t.to_unix_f)
  end

  it "converts Bytes to a SchemeBlob" do
    bytes = Bytes[1, 2, 3]
    Scheme.to_scheme(bytes).as(Scheme::SchemeBlob).value.should eq(bytes)
  end
end

describe "Scheme.from_scheme" do
  it "converts NIL to Crystal nil" do
    Scheme.from_scheme(Scheme::NIL).should be_nil
  end

  it "distinguishes NIL from #f" do
    Scheme.from_scheme(Scheme::NIL).should be_nil
    Scheme.from_scheme(Scheme::FALSE).should eq(false)
  end

  it "converts scalars" do
    Scheme.from_scheme(Scheme::SchemeInt.new(3_i64)).should eq(3_i64)
    Scheme.from_scheme(Scheme::SchemeFloat.new(1.5)).should eq(1.5)
    Scheme.from_scheme(Scheme::SchemeStr.new("hi")).should eq("hi")
    Scheme.from_scheme(Scheme::SchemeChar.new('x')).should eq("x")
    Scheme.from_scheme(Scheme::TRUE).should eq(true)
  end

  it "converts a SchemeVector to an Array, recursively" do
    vec = Scheme::SchemeVector.new([i(1_i64), i(2_i64)] of Scheme::SchemeValue)
    Scheme.from_scheme(vec).should eq([1_i64, 2_i64])
  end

  it "converts a proper, non-alist Cons list to an Array" do
    lst = Scheme.a_to_list([i(1_i64), i(2_i64), i(3_i64)])
    Scheme.from_scheme(lst).should eq([1_i64, 2_i64, 3_i64])
  end

  it "converts an alist-shaped Cons list to a Hash" do
    alist = Scheme.a_to_list([
      Scheme::Cons.new(Scheme::SchemeStr.new("name"), Scheme::SchemeStr.new("Ada")).as(Scheme::SchemeValue),
      Scheme::Cons.new(Scheme::SchemeStr.new("age"), i(36_i64)).as(Scheme::SchemeValue),
    ])
    Scheme.from_scheme(alist).should eq({"name" => "Ada", "age" => 36_i64})
  end

  it "resolves duplicate alist keys as first-occurrence-wins, matching assoc" do
    alist = Scheme.a_to_list([
      Scheme::Cons.new(Scheme::SchemeStr.new("a"), i(1_i64)).as(Scheme::SchemeValue),
      Scheme::Cons.new(Scheme::SchemeStr.new("a"), i(2_i64)).as(Scheme::SchemeValue),
    ])
    Scheme.from_scheme(alist).should eq({"a" => 1_i64})
  end

  it "treats a list of sub-lists as a plain (nested) array, not an alist" do
    lst = Scheme.a_to_list([
      Scheme.a_to_list([i(1_i64), i(2_i64)]),
      Scheme.a_to_list([i(3_i64), i(4_i64)]),
    ])
    Scheme.from_scheme(lst).should eq([[1_i64, 2_i64], [3_i64, 4_i64]])
  end

  it "raises for an improper (dotted) list" do
    dotted = Scheme::Cons.new(i(1_i64), i(2_i64))
    expect_raises(Scheme::SchemeRuntimeError, /cannot convert improper list/) do
      Scheme.from_scheme(dotted)
    end
  end

  it "raises for an opaque, non-data value" do
    lam = Scheme::Lambda.new([] of String, nil, [] of Scheme::SchemeValue, Scheme::Env.new)
    expect_raises(Scheme::SchemeRuntimeError, /cannot convert/) do
      Scheme.from_scheme(lam)
    end
  end

  it "converts a SchemeSym to its name" do
    Scheme.from_scheme(Scheme::SchemeSym.of("foo")).should eq("foo")
  end

  it "converts a list of symbols (previously raised entirely on the first element)" do
    lst = Scheme.a_to_list([Scheme::SchemeSym.of("a"), Scheme::SchemeSym.of("b")] of Scheme::SchemeValue)
    Scheme.from_scheme(lst).should eq(["a", "b"])
  end

  it "converts a SchemeBlob back to Bytes" do
    bytes = Bytes[1, 2, 3]
    Scheme.from_scheme(Scheme::SchemeBlob.new(bytes)).should eq(bytes)
  end
end

describe "Scheme.bind" do
  it "bulk-defines converted bindings into a given env" do
    env = Scheme::Env.new
    Scheme.bind(env, {"x" => 1, "y" => "hi"})
    env.get("x").as(Scheme::SchemeInt).value.should eq(1_i64)
    env.get("y").as(Scheme::SchemeStr).value.should eq("hi")
  end

  it "bulk-defines converted bindings into a fresh child of interp.global" do
    interp = Scheme::Interpreter.new
    env = Scheme.bind(interp, {"x" => 5})
    env.parent.should be(interp.global)
    env.get("x").as(Scheme::SchemeInt).value.should eq(5_i64)
  end

  it "isolates bindings from interp.global" do
    interp = Scheme::Interpreter.new
    Scheme.bind(interp, {"x" => 5})
    expect_raises(Scheme::SchemeRuntimeError, /unbound variable: x/) do
      interp.global.get("x")
    end
  end

  it "isolates bindings between two separate bind calls" do
    interp = Scheme::Interpreter.new
    env1 = Scheme.bind(interp, {"x" => 1})
    env2 = Scheme.bind(interp, {"x" => 2})
    env1.get("x").as(Scheme::SchemeInt).value.should eq(1_i64)
    env2.get("x").as(Scheme::SchemeInt).value.should eq(2_i64)
  end
end
