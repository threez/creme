require "../spec_helper"

private def i(n : Int64) : Scheme::SchemeValue
  Scheme::SchemeInt.new(n)
end

private def f(n : Float64) : Scheme::SchemeValue
  Scheme::SchemeFloat.new(n)
end

describe "Scheme.truthy?" do
  it "is false only for #f" do
    Scheme.truthy?(Scheme::FALSE).should be_false
  end

  it "is true for #t" do
    Scheme.truthy?(Scheme::TRUE).should be_true
  end

  it "is true for nil (the empty list)" do
    Scheme.truthy?(Scheme::NIL).should be_true
  end

  it "is true for 0" do
    Scheme.truthy?(i(0_i64)).should be_true
  end
end

describe "Scheme.list_to_a" do
  it "converts a proper list to an array" do
    lst = Scheme.a_to_list([i(1_i64), i(2_i64), i(3_i64)])
    Scheme.list_to_a(lst).map { |v| v.as(Scheme::SchemeInt).value }.should eq([1_i64, 2_i64, 3_i64])
  end

  it "converts nil to an empty array" do
    Scheme.list_to_a(Scheme::NIL).should be_empty
  end

  it "raises SchemeRuntimeError for an improper list" do
    dotted = Scheme::Cons.new(i(1_i64), i(2_i64))
    expect_raises(Scheme::SchemeRuntimeError, /improper list/) do
      Scheme.list_to_a(dotted)
    end
  end
end

describe "Scheme.a_to_list" do
  it "builds a proper list from an array" do
    Scheme.a_to_list([i(1_i64), i(2_i64)]).write_string.should eq("(1 2)")
  end

  it "builds a dotted list with a custom tail" do
    Scheme.a_to_list([i(1_i64)], i(2_i64)).write_string.should eq("(1 . 2)")
  end

  it "returns the tail directly for an empty array" do
    tail = i(9_i64)
    Scheme.a_to_list([] of Scheme::SchemeValue, tail).should eq(tail)
  end
end

describe "Scheme.proper_list?" do
  it "is true for nil" do
    Scheme.proper_list?(Scheme::NIL).should be_true
  end

  it "is true for a proper list" do
    Scheme.proper_list?(Scheme.a_to_list([i(1_i64)])).should be_true
  end

  it "is false for a dotted pair" do
    Scheme.proper_list?(Scheme::Cons.new(i(1_i64), i(2_i64))).should be_false
  end
end

describe "Scheme.as_f64" do
  it "coerces an int" do
    Scheme.as_f64(i(3_i64), "who").should eq(3.0)
  end

  it "passes through a float" do
    Scheme.as_f64(f(2.5), "who").should eq(2.5)
  end

  it "raises SchemeRuntimeError for a non-number" do
    expect_raises(Scheme::SchemeRuntimeError, /who: expected number/) do
      Scheme.as_f64(Scheme::NIL, "who")
    end
  end
end

describe "Scheme.num_binop" do
  add_i = ->(x : Int64, y : Int64) { x + y }
  add_f = ->(x : Float64, y : Float64) { x + y }

  it "computes int+int as an int" do
    result = Scheme.num_binop(i(1_i64), i(2_i64), "+", add_i, add_f)
    result.as(Scheme::SchemeInt).value.should eq(3_i64)
  end

  it "computes float+float as a float" do
    result = Scheme.num_binop(f(1.0), f(2.0), "+", add_i, add_f)
    result.as(Scheme::SchemeFloat).value.should eq(3.0)
  end

  it "computes mixed int/float as a float" do
    result = Scheme.num_binop(i(1_i64), f(2.0), "+", add_i, add_f)
    result.as(Scheme::SchemeFloat).value.should eq(3.0)
  end

  it "raises SchemeRuntimeError on integer overflow" do
    mul_i = ->(x : Int64, y : Int64) { x * y }
    mul_f = ->(x : Float64, y : Float64) { x * y }
    expect_raises(Scheme::SchemeRuntimeError, /integer overflow/) do
      Scheme.num_binop(i(Int64::MAX), i(2_i64), "*", mul_i, mul_f)
    end
  end
end

describe "Scheme.scheme_equal?" do
  it "compares ints by value" do
    Scheme.scheme_equal?(i(1_i64), i(1_i64)).should be_true
  end

  it "compares floats by value" do
    Scheme.scheme_equal?(f(1.0), f(1.0)).should be_true
  end

  it "compares rationals by reduced numerator/denominator" do
    Scheme.scheme_equal?(Scheme::SchemeRational.make(1_i64, 3_i64), Scheme::SchemeRational.make(2_i64, 6_i64)).should be_true
    Scheme.scheme_equal?(Scheme::SchemeRational.make(1_i64, 3_i64), Scheme::SchemeRational.make(1_i64, 4_i64)).should be_false
  end

  it "is false comparing a rational to an int, even a whole-valued one via a different numerator/denominator" do
    Scheme.scheme_equal?(Scheme::SchemeRational.make(1_i64, 3_i64), i(1_i64)).should be_false
  end

  it "compares strings by value" do
    Scheme.scheme_equal?(Scheme::SchemeStr.new("a"), Scheme::SchemeStr.new("a")).should be_true
  end

  it "compares chars by value" do
    Scheme.scheme_equal?(Scheme::SchemeChar.new('a'), Scheme::SchemeChar.new('a')).should be_true
  end

  it "compares bools by value" do
    Scheme.scheme_equal?(Scheme::TRUE, Scheme::SchemeBool.new(true)).should be_true
  end

  it "compares symbols by name" do
    Scheme.scheme_equal?(Scheme::SchemeSym.of("a"), Scheme::SchemeSym.of("a")).should be_true
  end

  it "compares nil to nil" do
    Scheme.scheme_equal?(Scheme::NIL, Scheme::SchemeNil.new).should be_true
  end

  it "deeply compares nested lists" do
    a = Scheme.a_to_list([i(1_i64), Scheme.a_to_list([i(2_i64), i(3_i64)])])
    b = Scheme.a_to_list([i(1_i64), Scheme.a_to_list([i(2_i64), i(3_i64)])])
    Scheme.scheme_equal?(a, b).should be_true
  end

  it "is false for mismatched types" do
    Scheme.scheme_equal?(i(1_i64), Scheme::SchemeStr.new("1")).should be_false
  end

  it "is false for lists of different length" do
    a = Scheme.a_to_list([i(1_i64), i(2_i64)])
    b = Scheme.a_to_list([i(1_i64)])
    Scheme.scheme_equal?(a, b).should be_false
  end

  it "falls back to identity for procedure values" do
    proc = Scheme::Builtin.new("dummy", 0, 0) { Scheme::NIL.as(Scheme::SchemeValue) }
    Scheme.scheme_equal?(proc, proc).should be_true
    Scheme.scheme_equal?(proc, Scheme::Builtin.new("dummy", 0, 0) { Scheme::NIL.as(Scheme::SchemeValue) }).should be_false
  end

  it "compares blobs by content" do
    Scheme.scheme_equal?(Scheme::SchemeBlob.new(Bytes[1, 2]), Scheme::SchemeBlob.new(Bytes[1, 2])).should be_true
    Scheme.scheme_equal?(Scheme::SchemeBlob.new(Bytes[1, 2]), Scheme::SchemeBlob.new(Bytes[1, 3])).should be_false
  end
end

describe "Scheme.scheme_eqv?" do
  it "compares ints by value" do
    Scheme.scheme_eqv?(i(1_i64), i(1_i64)).should be_true
  end

  it "compares floats by value" do
    Scheme.scheme_eqv?(f(1.0), f(1.0)).should be_true
  end

  it "compares rationals by reduced numerator/denominator" do
    Scheme.scheme_eqv?(Scheme::SchemeRational.make(1_i64, 3_i64), Scheme::SchemeRational.make(2_i64, 6_i64)).should be_true
    Scheme.scheme_eqv?(Scheme::SchemeRational.make(1_i64, 3_i64), Scheme::SchemeRational.make(1_i64, 4_i64)).should be_false
  end

  it "compares chars by value" do
    Scheme.scheme_eqv?(Scheme::SchemeChar.new('a'), Scheme::SchemeChar.new('a')).should be_true
  end

  it "compares bools by value" do
    Scheme.scheme_eqv?(Scheme::TRUE, Scheme::SchemeBool.new(true)).should be_true
  end

  it "compares symbols by name" do
    Scheme.scheme_eqv?(Scheme::SchemeSym.of("a"), Scheme::SchemeSym.of("a")).should be_true
  end

  it "compares nil to nil" do
    Scheme.scheme_eqv?(Scheme::NIL, Scheme::SchemeNil.new).should be_true
  end

  it "is false for two distinct string objects with equal content" do
    Scheme.scheme_eqv?(Scheme::SchemeStr.new("a"), Scheme::SchemeStr.new("a")).should be_false
  end

  it "is true for the same string object" do
    s = Scheme::SchemeStr.new("a")
    Scheme.scheme_eqv?(s, s).should be_true
  end

  it "is false for two distinct blob objects with equal content (identity only)" do
    Scheme.scheme_eqv?(Scheme::SchemeBlob.new(Bytes[1, 2]), Scheme::SchemeBlob.new(Bytes[1, 2])).should be_false
  end

  it "is true for the same blob object" do
    b = Scheme::SchemeBlob.new(Bytes[1, 2])
    Scheme.scheme_eqv?(b, b).should be_true
  end

  it "is false for two distinct records with equal fields (identity only)" do
    t = Scheme::SchemeRecordType.new("point", ["x"])
    Scheme.scheme_eqv?(
      Scheme::SchemeRecord.new(t, [i(1_i64)] of Scheme::SchemeValue),
      Scheme::SchemeRecord.new(t, [i(1_i64)] of Scheme::SchemeValue)
    ).should be_false
  end

  it "is true for the same record object" do
    t = Scheme::SchemeRecordType.new("point", ["x"])
    r = Scheme::SchemeRecord.new(t, [i(1_i64)] of Scheme::SchemeValue)
    Scheme.scheme_eqv?(r, r).should be_true
  end

  it "is false for two distinct parameters with the same value (identity only)" do
    Scheme.scheme_eqv?(Scheme::SchemeParameter.new(i(1_i64)), Scheme::SchemeParameter.new(i(1_i64))).should be_false
  end

  it "is true for the same parameter object" do
    p = Scheme::SchemeParameter.new(i(1_i64))
    Scheme.scheme_eqv?(p, p).should be_true
  end

  it "is false for two distinct promises, even wrapping the same thunk (identity only)" do
    thunk = Scheme::Builtin.new("dummy", 0, 0) { Scheme::NIL.as(Scheme::SchemeValue) }
    Scheme.scheme_eqv?(Scheme::SchemePromise.new(thunk), Scheme::SchemePromise.new(thunk)).should be_false
  end

  it "is true for the same promise object" do
    thunk = Scheme::Builtin.new("dummy", 0, 0) { Scheme::NIL.as(Scheme::SchemeValue) }
    p = Scheme::SchemePromise.new(thunk)
    Scheme.scheme_eqv?(p, p).should be_true
  end

  it "is false for two distinct (even empty) hash tables (identity only)" do
    Scheme.scheme_eqv?(Scheme::SchemeHashTable.new, Scheme::SchemeHashTable.new).should be_false
  end

  it "is true for the same hash table object" do
    h = Scheme::SchemeHashTable.new
    Scheme.scheme_eqv?(h, h).should be_true
  end
end
