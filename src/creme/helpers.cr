# ===========================================================================
# Numeric / list helpers
# ===========================================================================

module Creme
  def self.truthy?(v : SchemeValue) : Bool
    !(v.is_a?(SchemeBool) && v.value? == false)
  end

  def self.list_to_a(v : SchemeValue) : Array(SchemeValue)
    arr = [] of SchemeValue
    cur = v
    while cur.is_a?(Cons)
      arr << cur.car
      cur = cur.cdr
    end
    unless cur.is_a?(SchemeNil)
      raise SchemeRuntimeError.new("improper list: #{v.write_string}")
    end
    arr
  end

  def self.a_to_list(arr : Array(SchemeValue), tail : SchemeValue = NIL) : SchemeValue
    result = tail
    i = arr.size - 1
    while i >= 0
      result = Cons.new(arr[i], result)
      i -= 1
    end
    result
  end

  # Floyd's tortoise-and-hare: R7RS requires `list?` (this function's own
  # sole caller) to return #f -- not hang -- on a genuinely circular
  # list, which a plain single-pointer cdr-walk (this used to be one)
  # can't do by itself. `fast` advances two cdrs per iteration, `slow`
  # one; if they're ever object-identical again, `fast` has lapped
  # `slow` around a cycle. No extra memory needed (unlike a visited-set
  # approach), and terminates in O(n) either way.
  def self.proper_list?(v : SchemeValue) : Bool
    slow : SchemeValue = v
    fast : SchemeValue = v
    loop do
      return true if fast.is_a?(SchemeNil)
      return false unless fast.is_a?(Cons)
      fast = fast.cdr
      return true if fast.is_a?(SchemeNil)
      return false unless fast.is_a?(Cons)
      fast = fast.cdr
      slow = slow.as(Cons).cdr
      return false if fast.is_a?(Cons) && slow.is_a?(Cons) && fast.object_id == slow.object_id
    end
  end

  def self.as_f64(v : SchemeValue, who : String) : Float64
    case v
    when SchemeInt      then v.value.to_f64
    when SchemeBigInt   then v.value.to_f64
    when SchemeRational then v.numerator.to_f64 / v.denominator.to_f64
    when SchemeFloat    then v.value
    else
      raise SchemeRuntimeError.new("#{who}: expected number, got #{v.write_string}")
    end
  end

  def self.exact?(v : SchemeValue) : Bool
    v.is_a?(SchemeInt) || v.is_a?(SchemeBigInt) || v.is_a?(SchemeRational)
  end

  def self.inexact?(v : SchemeValue) : Bool
    v.is_a?(SchemeFloat)
  end

  # Promotion rank across the numeric tower: exact integer < exact rational
  # < inexact float. The higher-ranked operand's representation "wins" —
  # this is the one place that rule is expressed; num_binop3 promotes to
  # the max rank of its two operands rather than every call site
  # hand-writing the same 3-way case. SchemeBigInt ranks alongside
  # SchemeInt — both are just "an exact integer" to the tower.
  def self.num_rank(v : SchemeValue, who : String) : Int32
    case v
    when SchemeInt      then 0
    when SchemeBigInt   then 0
    when SchemeRational then 1
    when SchemeFloat    then 2
    else
      raise SchemeRuntimeError.new("#{who}: expected number, got #{v.write_string}")
    end
  end

  # Normalizes any exact number (SchemeInt, SchemeBigInt, or
  # SchemeRational) to a {numerator, denominator} pair, so rational-branch
  # arithmetic can treat an int as "n/1" without a separate case.
  def self.as_ratio(v : SchemeValue) : {RatInt, RatInt}
    case v
    when SchemeInt      then {v.value, 1_i64}
    when SchemeBigInt   then {v.value, 1_i64}
    when SchemeRational then {v.numerator, v.denominator}
    else                     raise SchemeRuntimeError.new("expected an exact number, got #{v.write_string}")
    end
  end

  # Legacy two-way (int/float only) dispatch — still used by round_like-style
  # callers that don't yet participate in the rational tower.
  def self.num_binop(a : SchemeValue, b : SchemeValue, who : String, int_op : Int64, Int64 -> Int64, flt_op : Float64, Float64 -> Float64) : SchemeValue
    if a.is_a?(SchemeInt) && b.is_a?(SchemeInt)
      begin
        SchemeInt.new(int_op.call(checked_i64(a.value, who), checked_i64(b.value, who)))
      rescue OverflowError
        raise SchemeRuntimeError.new("#{who}: integer overflow")
      end
    else
      SchemeFloat.new(flt_op.call(as_f64(a, who), as_f64(b, who)))
    end
  end

  # The shared 3-way numeric tower dispatcher: promotes to the higher rank
  # of a/b and calls the matching op. int_op handles int+int (staying
  # exact-integer); rat_op handles anything exact+exact where at least one
  # side is a rational (numerator/denominator pairs in, a SchemeValue out —
  # typically routed through SchemeRational.make so results stay reduced
  # and auto-collapse back to SchemeInt when possible); flt_op handles
  # anything+float (inexact contagion, unchanged from today's behavior).
  def self.num_binop3(
    a : SchemeValue, b : SchemeValue, who : String,
    int_op : RatInt, RatInt -> SchemeValue,
    rat_op : {RatInt, RatInt}, {RatInt, RatInt} -> SchemeValue,
    flt_op : Float64, Float64 -> Float64,
  ) : SchemeValue
    rank = Math.max(num_rank(a, who), num_rank(b, who))
    case rank
    when 0 then int_op.call(Creme.rat_of(a), Creme.rat_of(b))
    when 1 then rat_op.call(as_ratio(a), as_ratio(b))
    else        SchemeFloat.new(flt_op.call(as_f64(a, who), as_f64(b, who)))
    end
  end

  # R7RS requires equal? to terminate even on circular arguments. `seen`
  # tracks {a.object_id, b.object_id} pairs currently being compared
  # further up the same call — the standard cycle-tolerant equality
  # algorithm: if we're asked to compare the same pair again while already
  # in the middle of comparing it, the structures agree at every level
  # reached so far, so it's safe to assume equal? and not recurse forever.
  # Only Cons/SchemeVector can participate in a cycle (the other cases are
  # either atomic or, for strings/bytevectors, compared by value with no
  # further recursion), so only those two branches consult/extend `seen`.
  # ameba:disable Metrics/CyclomaticComplexity
  def self.scheme_equal?(a : SchemeValue, b : SchemeValue, seen : Set({UInt64, UInt64})? = nil) : Bool
    case a
    when SchemeInt
      b.is_a?(SchemeInt) && a.value == b.value
    when SchemeBigInt
      # A class, unlike SchemeInt — MUST compare by value here, not fall
      # through to the Reference#same? identity fallback below (two
      # distinct SchemeBigInt objects holding the same BigInt are equal?).
      b.is_a?(SchemeBigInt) && a.value == b.value
    when SchemeFloat
      b.is_a?(SchemeFloat) && a.value == b.value
    when SchemeRational
      b.is_a?(SchemeRational) && a.numerator == b.numerator && a.denominator == b.denominator
    when SchemeStr
      b.is_a?(SchemeStr) && a.value == b.value
    when SchemeChar
      b.is_a?(SchemeChar) && a.value == b.value
    when SchemeBool
      b.is_a?(SchemeBool) && a.value? == b.value?
    when SchemeSym
      b.is_a?(SchemeSym) && a.name == b.name
    when SchemeNil
      b.is_a?(SchemeNil)
    when Cons
      return false unless b.is_a?(Cons)
      pair = {a.object_id, b.object_id}
      seen ||= Set({UInt64, UInt64}).new
      return true unless seen.add?(pair)
      scheme_equal?(a.car, b.car, seen) && scheme_equal?(a.cdr, b.cdr, seen)
    when SchemeVector
      return false unless b.is_a?(SchemeVector)
      pair = {a.object_id, b.object_id}
      seen ||= Set({UInt64, UInt64}).new
      return true unless seen.add?(pair)
      vector_equal?(a, b, seen)
    when SchemeBlob
      b.is_a?(SchemeBlob) && a.value == b.value
    when SchemeTreelist
      b.is_a?(SchemeTreelist) && treelist_equal?(a.tree, b.tree, seen)
    when SchemeMutableTreelist
      b.is_a?(SchemeMutableTreelist) && treelist_equal?(a.tree, b.tree, seen)
    else
      # Reference-identity fallback for the remaining (all class-typed) value
      # kinds. `a` is narrowed to references here, but `b` is still the full
      # union — guard it, since a value-type (struct) `b` can never be the
      # same object as a reference `a`.
      b.is_a?(Reference) && a.same?(b)
    end
  end

  private def self.vector_equal?(a : SchemeVector, b : SchemeVector, seen : Set({UInt64, UInt64})) : Bool
    return false unless a.value.size == b.value.size
    a.value.each_with_index.all? { |v, i| scheme_equal?(v, b.value[i], seen) }
  end

  private def self.treelist_equal?(a : RRB::Tree, b : RRB::Tree, seen : Set({UInt64, UInt64})?) : Bool
    return false unless a.size == b.size
    ba = b.to_a
    a.to_a.each_with_index.all? { |v, i| scheme_equal?(v, ba[i], seen) }
  end

  # ameba:disable Metrics/CyclomaticComplexity
  def self.scheme_eqv?(a : SchemeValue, b : SchemeValue) : Bool
    case a
    when SchemeInt
      b.is_a?(SchemeInt) && a.value == b.value
    when SchemeBigInt
      # Same rationale as scheme_equal?'s own SchemeBigInt case above —
      # compare by value, don't fall through to the identity fallback.
      b.is_a?(SchemeBigInt) && a.value == b.value
    when SchemeFloat
      # Bit-pattern comparison, not ==, so 0.0 and -0.0 (which Float64#==
      # treats as equal) correctly compare unequal per R7RS — eqv? must
      # distinguish negative zero when the implementation distinguishes it
      # at all (this one does, via IEEE 754's sign bit).
      b.is_a?(SchemeFloat) && a.value.unsafe_as(Int64) == b.value.unsafe_as(Int64)
    when SchemeRational
      b.is_a?(SchemeRational) && a.numerator == b.numerator && a.denominator == b.denominator
    when SchemeChar
      b.is_a?(SchemeChar) && a.value == b.value
    when SchemeBool
      b.is_a?(SchemeBool) && a.value? == b.value?
    when SchemeSym
      b.is_a?(SchemeSym) && a.name == b.name
    when SchemeNil
      b.is_a?(SchemeNil)
    else
      # See scheme_equal?'s fallback: guard `b` so a value-type struct can't
      # reach Reference#same?.
      b.is_a?(Reference) && a.same?(b)
    end
  end

  # A structural hash consistent with scheme_equal? — any two values with
  # scheme_equal?(a, b) == true MUST produce the same scheme_hash (the
  # converse need not hold: unequal values may collide, that's an
  # ordinary hash bucket collision, not a correctness bug). Backs
  # SchemeHashTable's real O(1)-average bucket lookup (see
  # modules/creme/hash_table.cr) rather than the plain-Array linear scan
  # it used to be — a GROUP BY/JOIN-style workload doing one lookup per
  # row of a large CSV made that O(n) cost dominate in practice (profiled:
  # SchemeHashTable#unsafe_index_of/scheme_equal? alone ate real wall time
  # scanning a multi-million-row file, on top of the GC pressure that
  # linear rescanning caused).
  #
  # Cons/SchemeVector/treelists recurse into their elements, guarded
  # against a genuine cycle the same way scheme_equal? is (a `seen` set of
  # already-visited object ids) — re-entering one just contributes a fixed
  # value rather than looping forever. Every reference-identity-fallback
  # type in scheme_equal?'s own `else` branch (ports, closures, records,
  # hash tables, boxes, ...) hashes by object_id here too, consistent with
  # being compared by identity rather than structure.
  # ameba:disable Metrics/CyclomaticComplexity
  def self.scheme_hash(v : SchemeValue, seen : Set(UInt64)? = nil) : UInt64
    case v
    when SchemeInt      then v.value.hash
    when SchemeBigInt   then v.value.hash
    when SchemeFloat    then v.value.hash
    when SchemeRational then {v.numerator, v.denominator}.hash
    when SchemeStr      then v.value.hash
    when SchemeChar     then v.value.hash
    when SchemeBool     then v.value?.hash
    when SchemeSym      then v.name.hash
    when SchemeNil      then 0_u64
    when Cons
      id = v.object_id
      seen ||= Set(UInt64).new
      return 0_u64 unless seen.add?(id)
      combine_hash(scheme_hash(v.car, seen), scheme_hash(v.cdr, seen))
    when SchemeVector
      id = v.object_id
      seen ||= Set(UInt64).new
      return 0_u64 unless seen.add?(id)
      hash_sequence(v.value, seen)
    when SchemeBlob
      v.value.hash
    when SchemeTreelist
      hash_sequence(v.tree.to_a, seen)
    when SchemeMutableTreelist
      hash_sequence(v.tree.to_a, seen)
    else
      v.object_id.hash
    end
  end

  private def self.combine_hash(a : UInt64, b : UInt64) : UInt64
    a &* 31_u64 &+ b
  end

  private def self.hash_sequence(vs : Array(SchemeValue), seen : Set(UInt64)?) : UInt64
    vs.reduce(0_u64) { |acc, e| combine_hash(acc, scheme_hash(e, seen)) }
  end
end
