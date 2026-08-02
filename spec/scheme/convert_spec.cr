require "../spec_helper"

private def i(n : Int64) : Creme::SchemeValue
  Creme::SchemeInt.new(n)
end

describe "Creme.to_scheme" do
  it "converts nil to NIL" do
    Creme.to_scheme(nil).should eq(Creme::NIL)
  end

  it "converts a Bool" do
    Creme.to_scheme(true).should eq(Creme::TRUE)
    Creme.to_scheme(false).should eq(Creme::FALSE)
  end

  it "converts an Int" do
    Creme.to_scheme(42).as(Creme::SchemeInt).value.should eq(42_i64)
  end

  it "converts a Float" do
    Creme.to_scheme(1.5).as(Creme::SchemeFloat).value.should eq(1.5)
  end

  it "converts a String" do
    Creme.to_scheme("hi").as(Creme::SchemeStr).value.should eq("hi")
  end

  it "converts an Array to a SchemeVector, recursively" do
    vec = Creme.to_scheme([1, "a", true]).as(Creme::SchemeVector)
    vec.value[0].as(Creme::SchemeInt).value.should eq(1_i64)
    vec.value[1].as(Creme::SchemeStr).value.should eq("a")
    vec.value[2].should eq(Creme::TRUE)
  end

  it "converts a Hash to an alist of (SchemeStr . value), recursively" do
    pairs = Creme.list_to_a(Creme.to_scheme({"name" => "Ada", "age" => 36}))
    pairs.size.should eq(2)
    first = pairs[0].as(Creme::Cons)
    first.car.as(Creme::SchemeStr).value.should eq("name")
    first.cdr.as(Creme::SchemeStr).value.should eq("Ada")
    second = pairs[1].as(Creme::Cons)
    second.car.as(Creme::SchemeStr).value.should eq("age")
    second.cdr.as(Creme::SchemeInt).value.should eq(36_i64)
  end

  it "converts a JSON::Any by delegating to its raw value" do
    any = JSON.parse(%({"a": 1, "b": [true, null]}))
    result = Creme.from_scheme(Creme.to_scheme(any)).as(Hash(String, Creme::Convertible))
    result["a"].should eq(1_i64)
    result["b"].should eq([true, nil])
  end

  it "passes an already-built SchemeValue through unchanged (identity)" do
    v = Creme::SchemeInt.new(9_i64)
    Creme.to_scheme(v).should eq(v)
  end

  it "converts a Time to an epoch-second SchemeFloat" do
    t = Time.utc(2026, 1, 1)
    Creme.to_scheme(t).as(Creme::SchemeFloat).value.should eq(t.to_unix_f)
  end

  it "converts Bytes to a SchemeBlob" do
    bytes = Bytes[1, 2, 3]
    Creme.to_scheme(bytes).as(Creme::SchemeBlob).value.should eq(bytes)
  end
end

describe "Creme.from_scheme" do
  it "converts NIL to Crystal nil" do
    Creme.from_scheme(Creme::NIL).should be_nil
  end

  it "distinguishes NIL from #f" do
    Creme.from_scheme(Creme::NIL).should be_nil
    Creme.from_scheme(Creme::FALSE).should eq(false)
  end

  it "converts scalars" do
    Creme.from_scheme(Creme::SchemeInt.new(3_i64)).should eq(3_i64)
    Creme.from_scheme(Creme::SchemeFloat.new(1.5)).should eq(1.5)
    Creme.from_scheme(Creme::SchemeStr.new("hi")).should eq("hi")
    Creme.from_scheme(Creme::SchemeChar.new('x')).should eq("x")
    Creme.from_scheme(Creme::TRUE).should eq(true)
  end

  it "converts a SchemeVector to an Array, recursively" do
    vec = Creme::SchemeVector.new([i(1_i64), i(2_i64)] of Creme::SchemeValue)
    Creme.from_scheme(vec).should eq([1_i64, 2_i64])
  end

  it "converts a proper, non-alist Cons list to an Array" do
    lst = Creme.a_to_list([i(1_i64), i(2_i64), i(3_i64)])
    Creme.from_scheme(lst).should eq([1_i64, 2_i64, 3_i64])
  end

  it "converts an alist-shaped Cons list to a Hash" do
    alist = Creme.a_to_list([
      Creme::Cons.new(Creme::SchemeStr.new("name"), Creme::SchemeStr.new("Ada")).as(Creme::SchemeValue),
      Creme::Cons.new(Creme::SchemeStr.new("age"), i(36_i64)).as(Creme::SchemeValue),
    ])
    Creme.from_scheme(alist).should eq({"name" => "Ada", "age" => 36_i64})
  end

  it "resolves duplicate alist keys as first-occurrence-wins, matching assoc" do
    alist = Creme.a_to_list([
      Creme::Cons.new(Creme::SchemeStr.new("a"), i(1_i64)).as(Creme::SchemeValue),
      Creme::Cons.new(Creme::SchemeStr.new("a"), i(2_i64)).as(Creme::SchemeValue),
    ])
    Creme.from_scheme(alist).should eq({"a" => 1_i64})
  end

  it "treats a list of sub-lists as a plain (nested) array, not an alist" do
    lst = Creme.a_to_list([
      Creme.a_to_list([i(1_i64), i(2_i64)]),
      Creme.a_to_list([i(3_i64), i(4_i64)]),
    ])
    Creme.from_scheme(lst).should eq([[1_i64, 2_i64], [3_i64, 4_i64]])
  end

  it "raises for an improper (dotted) list" do
    dotted = Creme::Cons.new(i(1_i64), i(2_i64))
    expect_raises(Creme::SchemeRuntimeError, /cannot convert improper list/) do
      Creme.from_scheme(dotted)
    end
  end

  it "raises for an opaque, non-data value" do
    proc = Creme::Builtin.new("dummy", 0, 0) { Creme::NIL.as(Creme::SchemeValue) }
    expect_raises(Creme::SchemeRuntimeError, /cannot convert/) do
      Creme.from_scheme(proc)
    end
  end

  it "converts a SchemeSym to its name" do
    Creme.from_scheme(Creme::SchemeSym.of("foo")).should eq("foo")
  end

  it "converts a list of symbols (previously raised entirely on the first element)" do
    lst = Creme.a_to_list([Creme::SchemeSym.of("a"), Creme::SchemeSym.of("b")] of Creme::SchemeValue)
    Creme.from_scheme(lst).should eq(["a", "b"])
  end

  it "converts a SchemeBlob back to Bytes" do
    bytes = Bytes[1, 2, 3]
    Creme.from_scheme(Creme::SchemeBlob.new(bytes)).should eq(bytes)
  end
end

describe "Creme.bind" do
  it "bulk-defines converted bindings into a given env" do
    env = Creme::Env.new
    Creme.bind(env, {"x" => 1, "y" => "hi"})
    env.get("x").as(Creme::SchemeInt).value.should eq(1_i64)
    env.get("y").as(Creme::SchemeStr).value.should eq("hi")
  end

  it "bulk-defines converted bindings into a fresh child of interp.global" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    env = Creme.bind(interp, {"x" => 5})
    env.parent.should be(interp.global)
    env.get("x").as(Creme::SchemeInt).value.should eq(5_i64)
  end

  it "isolates bindings from interp.global" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    Creme.bind(interp, {"x" => 5})
    expect_raises(Creme::SchemeRuntimeError, /unbound variable: x/) do
      interp.global.get("x")
    end
  end

  it "isolates bindings between two separate bind calls" do
    interp = Creme::Interpreter.new(library_search_path: ["./modules"])
    env1 = Creme.bind(interp, {"x" => 1})
    env2 = Creme.bind(interp, {"x" => 2})
    env1.get("x").as(Creme::SchemeInt).value.should eq(1_i64)
    env2.get("x").as(Creme::SchemeInt).value.should eq(2_i64)
  end
end
