# ===========================================================================
# Numeric / list helpers
# ===========================================================================

module LISP
  def self.truthy?(v : LispValue) : Bool
    !(v.is_a?(LispBool) && v.value == false)
  end

  def self.list_to_a(v : LispValue) : Array(LispValue)
    arr = [] of LispValue
    cur = v
    while cur.is_a?(Cons)
      arr << cur.car
      cur = cur.cdr
    end
    unless cur.is_a?(LispNil)
      raise LispRuntimeError.new("improper list: #{v.write_string}")
    end
    arr
  end

  def self.a_to_list(arr : Array(LispValue), tail : LispValue = NIL) : LispValue
    result = tail
    i = arr.size - 1
    while i >= 0
      result = Cons.new(arr[i], result)
      i -= 1
    end
    result
  end

  def self.proper_list?(v : LispValue) : Bool
    cur = v
    while cur.is_a?(Cons)
      cur = cur.cdr
    end
    cur.is_a?(LispNil)
  end

  def self.as_f64(v : LispValue, who : String) : Float64
    case v
    when LispInt   then v.value.to_f64
    when LispFloat then v.value
    else
      raise LispRuntimeError.new("#{who}: expected number, got #{v.write_string}")
    end
  end

  def self.num_binop(a : LispValue, b : LispValue, who : String, int_op : Int64, Int64 -> Int64, flt_op : Float64, Float64 -> Float64) : LispValue
    if a.is_a?(LispInt) && b.is_a?(LispInt)
      begin
        LispInt.new(int_op.call(a.value, b.value))
      rescue OverflowError
        raise LispRuntimeError.new("#{who}: integer overflow")
      end
    else
      LispFloat.new(flt_op.call(as_f64(a, who), as_f64(b, who)))
    end
  end

  def self.lisp_equal?(a : LispValue, b : LispValue) : Bool
    case a
    when LispInt
      b.is_a?(LispInt) && a.value == b.value
    when LispFloat
      b.is_a?(LispFloat) && a.value == b.value
    when LispStr
      b.is_a?(LispStr) && a.value == b.value
    when LispChar
      b.is_a?(LispChar) && a.value == b.value
    when LispBool
      b.is_a?(LispBool) && a.value == b.value
    when LispSym
      b.is_a?(LispSym) && a.name == b.name
    when LispNil
      b.is_a?(LispNil)
    when Cons
      return false unless b.is_a?(Cons)
      lisp_equal?(a.car, b.car) && lisp_equal?(a.cdr, b.cdr)
    when LispVector
      b.is_a?(LispVector) && vector_equal?(a, b)
    else
      a.same?(b)
    end
  end

  private def self.vector_equal?(a : LispVector, b : LispVector) : Bool
    return false unless a.value.size == b.value.size
    a.value.each_with_index.all? { |v, i| lisp_equal?(v, b.value[i]) }
  end

  def self.lisp_eqv?(a : LispValue, b : LispValue) : Bool
    case a
    when LispInt
      b.is_a?(LispInt) && a.value == b.value
    when LispFloat
      b.is_a?(LispFloat) && a.value == b.value
    when LispChar
      b.is_a?(LispChar) && a.value == b.value
    when LispBool
      b.is_a?(LispBool) && a.value == b.value
    when LispSym
      b.is_a?(LispSym) && a.name == b.name
    when LispNil
      b.is_a?(LispNil)
    else
      a.same?(b)
    end
  end
end
