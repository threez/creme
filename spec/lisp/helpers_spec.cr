require "../spec_helper"

private def i(n : Int64) : LISP::LispValue
  LISP::LispInt.new(n)
end

private def f(n : Float64) : LISP::LispValue
  LISP::LispFloat.new(n)
end

describe "LISP.truthy?" do
  it "is false only for #f" do
    LISP.truthy?(LISP::FALSE).should be_false
  end

  it "is true for #t" do
    LISP.truthy?(LISP::TRUE).should be_true
  end

  it "is true for nil (the empty list)" do
    LISP.truthy?(LISP::NIL).should be_true
  end

  it "is true for 0" do
    LISP.truthy?(i(0_i64)).should be_true
  end
end

describe "LISP.list_to_a" do
  it "converts a proper list to an array" do
    lst = LISP.a_to_list([i(1_i64), i(2_i64), i(3_i64)])
    LISP.list_to_a(lst).map { |v| v.as(LISP::LispInt).value }.should eq([1_i64, 2_i64, 3_i64])
  end

  it "converts nil to an empty array" do
    LISP.list_to_a(LISP::NIL).should be_empty
  end

  it "raises LispRuntimeError for an improper list" do
    dotted = LISP::Cons.new(i(1_i64), i(2_i64))
    expect_raises(LISP::LispRuntimeError, /improper list/) do
      LISP.list_to_a(dotted)
    end
  end
end

describe "LISP.a_to_list" do
  it "builds a proper list from an array" do
    LISP.a_to_list([i(1_i64), i(2_i64)]).write_string.should eq("(1 2)")
  end

  it "builds a dotted list with a custom tail" do
    LISP.a_to_list([i(1_i64)], i(2_i64)).write_string.should eq("(1 . 2)")
  end

  it "returns the tail directly for an empty array" do
    tail = i(9_i64)
    LISP.a_to_list([] of LISP::LispValue, tail).should be(tail)
  end
end

describe "LISP.proper_list?" do
  it "is true for nil" do
    LISP.proper_list?(LISP::NIL).should be_true
  end

  it "is true for a proper list" do
    LISP.proper_list?(LISP.a_to_list([i(1_i64)])).should be_true
  end

  it "is false for a dotted pair" do
    LISP.proper_list?(LISP::Cons.new(i(1_i64), i(2_i64))).should be_false
  end
end

describe "LISP.as_f64" do
  it "coerces an int" do
    LISP.as_f64(i(3_i64), "who").should eq(3.0)
  end

  it "passes through a float" do
    LISP.as_f64(f(2.5), "who").should eq(2.5)
  end

  it "raises LispRuntimeError for a non-number" do
    expect_raises(LISP::LispRuntimeError, /who: expected number/) do
      LISP.as_f64(LISP::NIL, "who")
    end
  end
end

describe "LISP.num_binop" do
  add_i = ->(x : Int64, y : Int64) { x + y }
  add_f = ->(x : Float64, y : Float64) { x + y }

  it "computes int+int as an int" do
    result = LISP.num_binop(i(1_i64), i(2_i64), "+", add_i, add_f)
    result.as(LISP::LispInt).value.should eq(3_i64)
  end

  it "computes float+float as a float" do
    result = LISP.num_binop(f(1.0), f(2.0), "+", add_i, add_f)
    result.as(LISP::LispFloat).value.should eq(3.0)
  end

  it "computes mixed int/float as a float" do
    result = LISP.num_binop(i(1_i64), f(2.0), "+", add_i, add_f)
    result.as(LISP::LispFloat).value.should eq(3.0)
  end

  it "raises LispRuntimeError on integer overflow" do
    mul_i = ->(x : Int64, y : Int64) { x * y }
    mul_f = ->(x : Float64, y : Float64) { x * y }
    expect_raises(LISP::LispRuntimeError, /integer overflow/) do
      LISP.num_binop(i(Int64::MAX), i(2_i64), "*", mul_i, mul_f)
    end
  end
end

describe "LISP.lisp_equal?" do
  it "compares ints by value" do
    LISP.lisp_equal?(i(1_i64), i(1_i64)).should be_true
  end

  it "compares floats by value" do
    LISP.lisp_equal?(f(1.0), f(1.0)).should be_true
  end

  it "compares strings by value" do
    LISP.lisp_equal?(LISP::LispStr.new("a"), LISP::LispStr.new("a")).should be_true
  end

  it "compares chars by value" do
    LISP.lisp_equal?(LISP::LispChar.new('a'), LISP::LispChar.new('a')).should be_true
  end

  it "compares bools by value" do
    LISP.lisp_equal?(LISP::TRUE, LISP::LispBool.new(true)).should be_true
  end

  it "compares symbols by name" do
    LISP.lisp_equal?(LISP::LispSym.of("a"), LISP::LispSym.of("a")).should be_true
  end

  it "compares nil to nil" do
    LISP.lisp_equal?(LISP::NIL, LISP::LispNil.new).should be_true
  end

  it "deeply compares nested lists" do
    a = LISP.a_to_list([i(1_i64), LISP.a_to_list([i(2_i64), i(3_i64)])])
    b = LISP.a_to_list([i(1_i64), LISP.a_to_list([i(2_i64), i(3_i64)])])
    LISP.lisp_equal?(a, b).should be_true
  end

  it "is false for mismatched types" do
    LISP.lisp_equal?(i(1_i64), LISP::LispStr.new("1")).should be_false
  end

  it "is false for lists of different length" do
    a = LISP.a_to_list([i(1_i64), i(2_i64)])
    b = LISP.a_to_list([i(1_i64)])
    LISP.lisp_equal?(a, b).should be_false
  end

  it "falls back to identity for Lambda/Builtin values" do
    lam = LISP::Lambda.new([] of String, nil, [] of LISP::LispValue, LISP::Env.new)
    LISP.lisp_equal?(lam, lam).should be_true
    LISP.lisp_equal?(lam, LISP::Lambda.new([] of String, nil, [] of LISP::LispValue, LISP::Env.new)).should be_false
  end

  it "compares blobs by content" do
    LISP.lisp_equal?(LISP::LispBlob.new(Bytes[1, 2]), LISP::LispBlob.new(Bytes[1, 2])).should be_true
    LISP.lisp_equal?(LISP::LispBlob.new(Bytes[1, 2]), LISP::LispBlob.new(Bytes[1, 3])).should be_false
  end
end

describe "LISP.lisp_eqv?" do
  it "compares ints by value" do
    LISP.lisp_eqv?(i(1_i64), i(1_i64)).should be_true
  end

  it "compares floats by value" do
    LISP.lisp_eqv?(f(1.0), f(1.0)).should be_true
  end

  it "compares chars by value" do
    LISP.lisp_eqv?(LISP::LispChar.new('a'), LISP::LispChar.new('a')).should be_true
  end

  it "compares bools by value" do
    LISP.lisp_eqv?(LISP::TRUE, LISP::LispBool.new(true)).should be_true
  end

  it "compares symbols by name" do
    LISP.lisp_eqv?(LISP::LispSym.of("a"), LISP::LispSym.of("a")).should be_true
  end

  it "compares nil to nil" do
    LISP.lisp_eqv?(LISP::NIL, LISP::LispNil.new).should be_true
  end

  it "is false for two distinct string objects with equal content" do
    LISP.lisp_eqv?(LISP::LispStr.new("a"), LISP::LispStr.new("a")).should be_false
  end

  it "is true for the same string object" do
    s = LISP::LispStr.new("a")
    LISP.lisp_eqv?(s, s).should be_true
  end

  it "is false for two distinct blob objects with equal content (identity only)" do
    LISP.lisp_eqv?(LISP::LispBlob.new(Bytes[1, 2]), LISP::LispBlob.new(Bytes[1, 2])).should be_false
  end

  it "is true for the same blob object" do
    b = LISP::LispBlob.new(Bytes[1, 2])
    LISP.lisp_eqv?(b, b).should be_true
  end
end
