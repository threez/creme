require "../spec_helper"

private def i(n : Int64) : LISP::LispValue
  LISP::LispInt.new(n)
end

describe "LISP.to_lisp" do
  it "converts nil to NIL" do
    LISP.to_lisp(nil).should be(LISP::NIL)
  end

  it "converts a Bool" do
    LISP.to_lisp(true).should be(LISP::TRUE)
    LISP.to_lisp(false).should be(LISP::FALSE)
  end

  it "converts an Int" do
    LISP.to_lisp(42).as(LISP::LispInt).value.should eq(42_i64)
  end

  it "converts a Float" do
    LISP.to_lisp(1.5).as(LISP::LispFloat).value.should eq(1.5)
  end

  it "converts a String" do
    LISP.to_lisp("hi").as(LISP::LispStr).value.should eq("hi")
  end

  it "converts an Array to a LispVector, recursively" do
    vec = LISP.to_lisp([1, "a", true]).as(LISP::LispVector)
    vec.value[0].as(LISP::LispInt).value.should eq(1_i64)
    vec.value[1].as(LISP::LispStr).value.should eq("a")
    vec.value[2].should be(LISP::TRUE)
  end

  it "converts a Hash to an alist of (LispStr . value), recursively" do
    pairs = LISP.list_to_a(LISP.to_lisp({"name" => "Ada", "age" => 36}))
    pairs.size.should eq(2)
    first = pairs[0].as(LISP::Cons)
    first.car.as(LISP::LispStr).value.should eq("name")
    first.cdr.as(LISP::LispStr).value.should eq("Ada")
    second = pairs[1].as(LISP::Cons)
    second.car.as(LISP::LispStr).value.should eq("age")
    second.cdr.as(LISP::LispInt).value.should eq(36_i64)
  end

  it "converts a JSON::Any by delegating to its raw value" do
    any = JSON.parse(%({"a": 1, "b": [true, null]}))
    result = LISP.from_lisp(LISP.to_lisp(any)).as(Hash(String, LISP::Convertible))
    result["a"].should eq(1_i64)
    result["b"].should eq([true, nil])
  end

  it "passes an already-built LispValue through unchanged (identity)" do
    v = LISP::LispInt.new(9_i64)
    LISP.to_lisp(v).should be(v)
  end

  it "converts a Time to an epoch-second LispFloat" do
    t = Time.utc(2026, 1, 1)
    LISP.to_lisp(t).as(LISP::LispFloat).value.should eq(t.to_unix_f)
  end

  it "converts Bytes to a LispBlob" do
    bytes = Bytes[1, 2, 3]
    LISP.to_lisp(bytes).as(LISP::LispBlob).value.should eq(bytes)
  end
end

describe "LISP.from_lisp" do
  it "converts NIL to Crystal nil" do
    LISP.from_lisp(LISP::NIL).should be_nil
  end

  it "distinguishes NIL from #f" do
    LISP.from_lisp(LISP::NIL).should be_nil
    LISP.from_lisp(LISP::FALSE).should eq(false)
  end

  it "converts scalars" do
    LISP.from_lisp(LISP::LispInt.new(3_i64)).should eq(3_i64)
    LISP.from_lisp(LISP::LispFloat.new(1.5)).should eq(1.5)
    LISP.from_lisp(LISP::LispStr.new("hi")).should eq("hi")
    LISP.from_lisp(LISP::LispChar.new('x')).should eq("x")
    LISP.from_lisp(LISP::TRUE).should eq(true)
  end

  it "converts a LispVector to an Array, recursively" do
    vec = LISP::LispVector.new([i(1_i64), i(2_i64)] of LISP::LispValue)
    LISP.from_lisp(vec).should eq([1_i64, 2_i64])
  end

  it "converts a proper, non-alist Cons list to an Array" do
    lst = LISP.a_to_list([i(1_i64), i(2_i64), i(3_i64)])
    LISP.from_lisp(lst).should eq([1_i64, 2_i64, 3_i64])
  end

  it "converts an alist-shaped Cons list to a Hash" do
    alist = LISP.a_to_list([
      LISP::Cons.new(LISP::LispStr.new("name"), LISP::LispStr.new("Ada")).as(LISP::LispValue),
      LISP::Cons.new(LISP::LispStr.new("age"), i(36_i64)).as(LISP::LispValue),
    ])
    LISP.from_lisp(alist).should eq({"name" => "Ada", "age" => 36_i64})
  end

  it "resolves duplicate alist keys as first-occurrence-wins, matching assoc" do
    alist = LISP.a_to_list([
      LISP::Cons.new(LISP::LispStr.new("a"), i(1_i64)).as(LISP::LispValue),
      LISP::Cons.new(LISP::LispStr.new("a"), i(2_i64)).as(LISP::LispValue),
    ])
    LISP.from_lisp(alist).should eq({"a" => 1_i64})
  end

  it "treats a list of sub-lists as a plain (nested) array, not an alist" do
    lst = LISP.a_to_list([
      LISP.a_to_list([i(1_i64), i(2_i64)]),
      LISP.a_to_list([i(3_i64), i(4_i64)]),
    ])
    LISP.from_lisp(lst).should eq([[1_i64, 2_i64], [3_i64, 4_i64]])
  end

  it "raises for an improper (dotted) list" do
    dotted = LISP::Cons.new(i(1_i64), i(2_i64))
    expect_raises(LISP::LispRuntimeError, /cannot convert improper list/) do
      LISP.from_lisp(dotted)
    end
  end

  it "raises for an opaque, non-data value" do
    lam = LISP::Lambda.new([] of String, nil, [] of LISP::LispValue, LISP::Env.new)
    expect_raises(LISP::LispRuntimeError, /cannot convert/) do
      LISP.from_lisp(lam)
    end
  end

  it "converts a LispSym to its name" do
    LISP.from_lisp(LISP::LispSym.of("foo")).should eq("foo")
  end

  it "converts a list of symbols (previously raised entirely on the first element)" do
    lst = LISP.a_to_list([LISP::LispSym.of("a"), LISP::LispSym.of("b")] of LISP::LispValue)
    LISP.from_lisp(lst).should eq(["a", "b"])
  end

  it "converts a LispBlob back to Bytes" do
    bytes = Bytes[1, 2, 3]
    LISP.from_lisp(LISP::LispBlob.new(bytes)).should eq(bytes)
  end
end

describe "LISP.bind" do
  it "bulk-defines converted bindings into a given env" do
    env = LISP::Env.new
    LISP.bind(env, {"x" => 1, "y" => "hi"})
    env.get("x").as(LISP::LispInt).value.should eq(1_i64)
    env.get("y").as(LISP::LispStr).value.should eq("hi")
  end

  it "bulk-defines converted bindings into a fresh child of interp.global" do
    interp = LISP::Interpreter.new
    env = LISP.bind(interp, {"x" => 5})
    env.parent.should be(interp.global)
    env.get("x").as(LISP::LispInt).value.should eq(5_i64)
  end

  it "isolates bindings from interp.global" do
    interp = LISP::Interpreter.new
    LISP.bind(interp, {"x" => 5})
    expect_raises(LISP::LispRuntimeError, /unbound variable: x/) do
      interp.global.get("x")
    end
  end

  it "isolates bindings between two separate bind calls" do
    interp = LISP::Interpreter.new
    env1 = LISP.bind(interp, {"x" => 1})
    env2 = LISP.bind(interp, {"x" => 2})
    env1.get("x").as(LISP::LispInt).value.should eq(1_i64)
    env2.get("x").as(LISP::LispInt).value.should eq(2_i64)
  end
end
