require "../spec_helper"

private def i(n : Int64) : Creme::SchemeValue
  Creme::SchemeInt.new(n)
end

private def f(n : Float64) : Creme::SchemeValue
  Creme::SchemeFloat.new(n)
end

describe "Creme.truthy?" do
  it "is false only for #f" do
    Creme.truthy?(Creme::FALSE).should be_false
  end

  it "is true for #t" do
    Creme.truthy?(Creme::TRUE).should be_true
  end

  it "is true for nil (the empty list)" do
    Creme.truthy?(Creme::NIL).should be_true
  end

  it "is true for 0" do
    Creme.truthy?(i(0_i64)).should be_true
  end
end

describe "Creme.list_to_a" do
  it "converts a proper list to an array" do
    lst = Creme.a_to_list([i(1_i64), i(2_i64), i(3_i64)])
    Creme.list_to_a(lst).map { |v| v.as(Creme::SchemeInt).value }.should eq([1_i64, 2_i64, 3_i64])
  end

  it "converts nil to an empty array" do
    Creme.list_to_a(Creme::NIL).should be_empty
  end

  it "raises SchemeRuntimeError for an improper list" do
    dotted = Creme::Cons.new(i(1_i64), i(2_i64))
    expect_raises(Creme::SchemeRuntimeError, /improper list/) do
      Creme.list_to_a(dotted)
    end
  end
end

describe "Creme.a_to_list" do
  it "builds a proper list from an array" do
    Creme.a_to_list([i(1_i64), i(2_i64)]).write_string.should eq("(1 2)")
  end

  it "builds a dotted list with a custom tail" do
    Creme.a_to_list([i(1_i64)], i(2_i64)).write_string.should eq("(1 . 2)")
  end

  it "returns the tail directly for an empty array" do
    tail = i(9_i64)
    Creme.a_to_list([] of Creme::SchemeValue, tail).should eq(tail)
  end
end

describe "Creme.proper_list?" do
  it "is true for nil" do
    Creme.proper_list?(Creme::NIL).should be_true
  end

  it "is true for a proper list" do
    Creme.proper_list?(Creme.a_to_list([i(1_i64)])).should be_true
  end

  it "is false for a dotted pair" do
    Creme.proper_list?(Creme::Cons.new(i(1_i64), i(2_i64))).should be_false
  end
end

describe "Creme.as_f64" do
  it "coerces an int" do
    Creme.as_f64(i(3_i64), "who").should eq(3.0)
  end

  it "passes through a float" do
    Creme.as_f64(f(2.5), "who").should eq(2.5)
  end

  it "raises SchemeRuntimeError for a non-number" do
    expect_raises(Creme::SchemeRuntimeError, /who: expected number/) do
      Creme.as_f64(Creme::NIL, "who")
    end
  end
end

describe "Creme.num_binop" do
  add_i = ->(x : Int64, y : Int64) { x + y }
  add_f = ->(x : Float64, y : Float64) { x + y }

  it "computes int+int as an int" do
    result = Creme.num_binop(i(1_i64), i(2_i64), "+", add_i, add_f)
    result.as(Creme::SchemeInt).value.should eq(3_i64)
  end

  it "computes float+float as a float" do
    result = Creme.num_binop(f(1.0), f(2.0), "+", add_i, add_f)
    result.as(Creme::SchemeFloat).value.should eq(3.0)
  end

  it "computes mixed int/float as a float" do
    result = Creme.num_binop(i(1_i64), f(2.0), "+", add_i, add_f)
    result.as(Creme::SchemeFloat).value.should eq(3.0)
  end

  it "raises SchemeRuntimeError on integer overflow" do
    mul_i = ->(x : Int64, y : Int64) { x * y }
    mul_f = ->(x : Float64, y : Float64) { x * y }
    expect_raises(Creme::SchemeRuntimeError, /integer overflow/) do
      Creme.num_binop(i(Int64::MAX), i(2_i64), "*", mul_i, mul_f)
    end
  end
end

describe "Creme.scheme_equal?" do
  it "compares ints by value" do
    Creme.scheme_equal?(i(1_i64), i(1_i64)).should be_true
  end

  it "compares floats by value" do
    Creme.scheme_equal?(f(1.0), f(1.0)).should be_true
  end

  it "compares rationals by reduced numerator/denominator" do
    Creme.scheme_equal?(Creme::SchemeRational.make(1_i64, 3_i64), Creme::SchemeRational.make(2_i64, 6_i64)).should be_true
    Creme.scheme_equal?(Creme::SchemeRational.make(1_i64, 3_i64), Creme::SchemeRational.make(1_i64, 4_i64)).should be_false
  end

  it "is false comparing a rational to an int, even a whole-valued one via a different numerator/denominator" do
    Creme.scheme_equal?(Creme::SchemeRational.make(1_i64, 3_i64), i(1_i64)).should be_false
  end

  it "compares strings by value" do
    Creme.scheme_equal?(Creme::SchemeStr.new("a"), Creme::SchemeStr.new("a")).should be_true
  end

  it "compares chars by value" do
    Creme.scheme_equal?(Creme::SchemeChar.new('a'), Creme::SchemeChar.new('a')).should be_true
  end

  it "compares bools by value" do
    Creme.scheme_equal?(Creme::TRUE, Creme::SchemeBool.new(true)).should be_true
  end

  it "compares symbols by name" do
    Creme.scheme_equal?(Creme::SchemeSym.of("a"), Creme::SchemeSym.of("a")).should be_true
  end

  it "compares nil to nil" do
    Creme.scheme_equal?(Creme::NIL, Creme::SchemeNil.new).should be_true
  end

  it "deeply compares nested lists" do
    a = Creme.a_to_list([i(1_i64), Creme.a_to_list([i(2_i64), i(3_i64)])])
    b = Creme.a_to_list([i(1_i64), Creme.a_to_list([i(2_i64), i(3_i64)])])
    Creme.scheme_equal?(a, b).should be_true
  end

  it "is false for mismatched types" do
    Creme.scheme_equal?(i(1_i64), Creme::SchemeStr.new("1")).should be_false
  end

  it "is false for lists of different length" do
    a = Creme.a_to_list([i(1_i64), i(2_i64)])
    b = Creme.a_to_list([i(1_i64)])
    Creme.scheme_equal?(a, b).should be_false
  end

  it "falls back to identity for procedure values" do
    proc = Creme::Builtin.new("dummy", 0, 0) { Creme::NIL.as(Creme::SchemeValue) }
    Creme.scheme_equal?(proc, proc).should be_true
    Creme.scheme_equal?(proc, Creme::Builtin.new("dummy", 0, 0) { Creme::NIL.as(Creme::SchemeValue) }).should be_false
  end

  it "compares blobs by content" do
    Creme.scheme_equal?(Creme::SchemeBlob.new(Bytes[1, 2]), Creme::SchemeBlob.new(Bytes[1, 2])).should be_true
    Creme.scheme_equal?(Creme::SchemeBlob.new(Bytes[1, 2]), Creme::SchemeBlob.new(Bytes[1, 3])).should be_false
  end
end

describe "Creme.scheme_eqv?" do
  it "compares ints by value" do
    Creme.scheme_eqv?(i(1_i64), i(1_i64)).should be_true
  end

  it "compares floats by value" do
    Creme.scheme_eqv?(f(1.0), f(1.0)).should be_true
  end

  it "compares rationals by reduced numerator/denominator" do
    Creme.scheme_eqv?(Creme::SchemeRational.make(1_i64, 3_i64), Creme::SchemeRational.make(2_i64, 6_i64)).should be_true
    Creme.scheme_eqv?(Creme::SchemeRational.make(1_i64, 3_i64), Creme::SchemeRational.make(1_i64, 4_i64)).should be_false
  end

  it "compares chars by value" do
    Creme.scheme_eqv?(Creme::SchemeChar.new('a'), Creme::SchemeChar.new('a')).should be_true
  end

  it "compares bools by value" do
    Creme.scheme_eqv?(Creme::TRUE, Creme::SchemeBool.new(true)).should be_true
  end

  it "compares symbols by name" do
    Creme.scheme_eqv?(Creme::SchemeSym.of("a"), Creme::SchemeSym.of("a")).should be_true
  end

  it "compares nil to nil" do
    Creme.scheme_eqv?(Creme::NIL, Creme::SchemeNil.new).should be_true
  end

  it "is false for two distinct string objects with equal content" do
    Creme.scheme_eqv?(Creme::SchemeStr.new("a"), Creme::SchemeStr.new("a")).should be_false
  end

  it "is true for the same string object" do
    s = Creme::SchemeStr.new("a")
    Creme.scheme_eqv?(s, s).should be_true
  end

  it "is false for two distinct blob objects with equal content (identity only)" do
    Creme.scheme_eqv?(Creme::SchemeBlob.new(Bytes[1, 2]), Creme::SchemeBlob.new(Bytes[1, 2])).should be_false
  end

  it "is true for the same blob object" do
    b = Creme::SchemeBlob.new(Bytes[1, 2])
    Creme.scheme_eqv?(b, b).should be_true
  end

  it "is false for two distinct records with equal fields (identity only)" do
    t = Creme::SchemeRecordType.new("point", ["x"])
    Creme.scheme_eqv?(
      Creme::SchemeRecord.new(t, [i(1_i64)] of Creme::SchemeValue),
      Creme::SchemeRecord.new(t, [i(1_i64)] of Creme::SchemeValue)
    ).should be_false
  end

  it "is true for the same record object" do
    t = Creme::SchemeRecordType.new("point", ["x"])
    r = Creme::SchemeRecord.new(t, [i(1_i64)] of Creme::SchemeValue)
    Creme.scheme_eqv?(r, r).should be_true
  end

  it "is false for two distinct parameters with the same value (identity only)" do
    Creme.scheme_eqv?(Creme::SchemeParameter.new(i(1_i64)), Creme::SchemeParameter.new(i(1_i64))).should be_false
  end

  it "is true for the same parameter object" do
    p = Creme::SchemeParameter.new(i(1_i64))
    Creme.scheme_eqv?(p, p).should be_true
  end

  it "is false for two distinct promises, even wrapping the same thunk (identity only)" do
    thunk = Creme::Builtin.new("dummy", 0, 0) { Creme::NIL.as(Creme::SchemeValue) }
    Creme.scheme_eqv?(Creme::SchemePromise.new(thunk), Creme::SchemePromise.new(thunk)).should be_false
  end

  it "is true for the same promise object" do
    thunk = Creme::Builtin.new("dummy", 0, 0) { Creme::NIL.as(Creme::SchemeValue) }
    p = Creme::SchemePromise.new(thunk)
    Creme.scheme_eqv?(p, p).should be_true
  end

  it "is false for two distinct (even empty) hash tables (identity only)" do
    Creme.scheme_eqv?(Creme::SchemeHashTable.new, Creme::SchemeHashTable.new).should be_false
  end

  it "is true for the same hash table object" do
    h = Creme::SchemeHashTable.new
    Creme.scheme_eqv?(h, h).should be_true
  end
end
