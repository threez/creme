# ===========================================================================
# Exact rationals (and the SchemeInt/SchemeBigInt overflow escape)
#
# SchemeInt/SchemeBigInt/SchemeRational/SchemeFloat form the numeric tower:
# the first three are exact, SchemeFloat is inexact. SchemeRational's own
# numerator/denominator are RatInt = Int64 | BigInt: the common case stays
# plain machine-width Int64 (checked arithmetic, no allocation), and only
# escapes to BigInt (Crystal's GMP-backed arbitrary-precision type, require
# "big") when an operation would actually overflow — mirroring icecreme's
# own T_RATIONAL, which has always worked this way. Every construction
# path demotes a BigInt back to Int64 whenever it fits (see
# Creme.rat_demote/Creme.int_value), so two mathematically-equal exact
# integers are ALWAYS represented as the same Scheme type (both SchemeInt,
# or both SchemeBigInt) regardless of computation history — this is what
# keeps helpers.cr's scheme_equal?/scheme_eqv?/scheme_hash correct without
# needing any special "which representation" reconciliation.
# ===========================================================================

require "big"

module Creme
  alias RatInt = Int64 | BigInt

  # Fast Int64 op, escaping to BigInt only on overflow (rescue, not a
  # pre-check — the common case never pays for the check). Unconditionally
  # BigInt if either operand already is one (no silent narrowing).
  def self.rat_add(a : RatInt, b : RatInt) : RatInt
    if a.is_a?(Int64) && b.is_a?(Int64)
      begin
        a + b
      rescue OverflowError
        a.to_big_i + b.to_big_i
      end
    else
      to_big_i(a) + to_big_i(b)
    end
  end

  def self.rat_sub(a : RatInt, b : RatInt) : RatInt
    if a.is_a?(Int64) && b.is_a?(Int64)
      begin
        a - b
      rescue OverflowError
        a.to_big_i - b.to_big_i
      end
    else
      to_big_i(a) - to_big_i(b)
    end
  end

  def self.rat_mul(a : RatInt, b : RatInt) : RatInt
    if a.is_a?(Int64) && b.is_a?(Int64)
      begin
        a * b
      rescue OverflowError
        a.to_big_i * b.to_big_i
      end
    else
      to_big_i(a) * to_big_i(b)
    end
  end

  # Truncating (%/quotient-style remainder), remainder (sign-of-dividend),
  # and floor-division counterparts of the above, for modulo/remainder/
  # quotient/floor-quotient. The only overflow risk in any of these is the
  # Int64::MIN / -1 edge case (the one division whose quotient doesn't fit
  # back in Int64) — rescued the same way as the arithmetic ops above.
  def self.rat_mod(a : RatInt, b : RatInt) : RatInt
    if a.is_a?(Int64) && b.is_a?(Int64)
      begin
        a % b
      rescue OverflowError
        to_big_i(a) % to_big_i(b)
      end
    else
      to_big_i(a) % to_big_i(b)
    end
  end

  def self.rat_remainder(a : RatInt, b : RatInt) : RatInt
    if a.is_a?(Int64) && b.is_a?(Int64)
      begin
        a.remainder(b)
      rescue OverflowError
        to_big_i(a).remainder(to_big_i(b))
      end
    else
      to_big_i(a).remainder(to_big_i(b))
    end
  end

  def self.rat_tdiv(a : RatInt, b : RatInt) : RatInt
    if a.is_a?(Int64) && b.is_a?(Int64)
      begin
        a.tdiv(b)
      rescue OverflowError
        to_big_i(a).tdiv(to_big_i(b))
      end
    else
      to_big_i(a).tdiv(to_big_i(b))
    end
  end

  # Int64::MIN.abs is the one unary case that can itself overflow (its
  # magnitude, 2**63, doesn't fit back in Int64) — escapes to BigInt the
  # same way the binary ops above do.
  def self.rat_abs(x : RatInt) : RatInt
    x.is_a?(BigInt) ? x.abs : (x.abs rescue x.to_big_i.abs)
  end

  # Demotes a BigInt back to Int64 when it fits, otherwise returns it
  # unchanged. The single place "does this still need to be big" is
  # decided, so every construction path can call it uniformly.
  def self.rat_demote(x : BigInt) : RatInt
    x.to_i64
  rescue OverflowError
    x
  end

  # Identity for BigInt, promotes for Int64 — the inverse of rat_demote,
  # used wherever an operation is easier to express purely in BigInt terms
  # (comparisons, gcd) than by hand-rolling a mixed-type fast path.
  def self.to_big_i(x : RatInt) : BigInt
    x.is_a?(BigInt) ? x : x.to_big_i
  end

  # The canonicalizing entry point for wrapping an arithmetic result (or a
  # rational collapsing to a whole number) as the right exact-integer
  # SchemeValue — SchemeInt for anything that fits Int64 (demoting via
  # rat_demote first if needed), SchemeBigInt otherwise. Every arithmetic
  # builtin that produces "an integer" from a RatInt goes through this
  # rather than constructing SchemeInt/SchemeBigInt directly, so the
  # "never store a BigInt that fits Int64" invariant is upheld in exactly
  # one place.
  def self.int_value(v : RatInt) : SchemeValue
    demoted = v.is_a?(BigInt) ? rat_demote(v) : v
    demoted.is_a?(Int64) ? SchemeInt.new(demoted) : SchemeBigInt.new(demoted.as(BigInt))
  end

  # The inverse of int_value: extracts the RatInt out of a SchemeInt or
  # SchemeBigInt (the two SchemeValue variants that make up "an exact
  # integer"). Used by numeric-tower dispatch (num_binop3's int_op branch,
  # as_ratio, ...) that needs to treat both representations uniformly.
  def self.rat_of(v : SchemeValue) : RatInt
    case v
    when SchemeInt    then v.value
    when SchemeBigInt then v.value
    else                   raise SchemeRuntimeError.new("expected an exact integer, got #{v.write_string}")
    end
  end

  # For call sites that need a genuine machine-width value (vector/string
  # indices, byte values, radixes, ...) rather than an arithmetic result —
  # a RatInt that's a too-large BigInt there means "out of range", not
  # "escalate", so this raises instead of silently truncating.
  def self.checked_i64(x : RatInt, who : String) : Int64
    return x if x.is_a?(Int64)
    x.to_i64
  rescue OverflowError
    raise SchemeRuntimeError.new("#{who}: integer out of range")
  end

  def self.checked_i32(x : RatInt, who : String) : Int32
    checked_i64(x, who).to_i32
  rescue OverflowError
    raise SchemeRuntimeError.new("#{who}: integer out of range")
  end

  # Euclidean algorithm; always returns a non-negative result (R7RS: (gcd) is
  # 0, gcd is otherwise always >= 0 regardless of operand signs). This is the
  # single implementation shared by SchemeRational's internal reduction and
  # the public gcd/lcm builtins. Kept monomorphic inside each loop (all-Int64
  # or all-BigInt) rather than mixing types mid-loop — Crystal's Int64/BigInt
  # binary operators don't accept a RatInt union argument directly (only a
  # single concrete type each), so a genuinely mixed pair is promoted to
  # BigInt up front instead.
  def self.rat_gcd(a : RatInt, b : RatInt) : RatInt
    if a.is_a?(Int64) && b.is_a?(Int64)
      ia, ib = a.abs, b.abs
      while ib != 0
        ia, ib = ib, ia % ib
      end
      ia
    else
      ba, bb = to_big_i(a).abs, to_big_i(b).abs
      while bb != 0
        ba, bb = bb, ba % bb
      end
      rat_demote(ba)
    end
  end

  def self.rat_lcm(a : RatInt, b : RatInt) : RatInt
    return 0_i64 if a == 0 || b == 0
    g = rat_gcd(a, b)
    rat_mul(int_div(a, g), b).abs
  end

  # An exact non-integer rational. Never publicly constructed directly (see
  # SchemeRational.make) so "already reduced, positive denominator, never
  # denominator 1" is a structural guarantee, not a convention every call
  # site has to remember.
  class SchemeRational
    include SchemeBaseValue
    getter numerator : RatInt
    getter denominator : RatInt

    private def initialize(@numerator : RatInt, @denominator : RatInt)
    end

    # The only public constructor. Reduces to lowest terms and normalizes
    # the denominator to positive; returns a SchemeInt/SchemeBigInt instead
    # when the ratio is actually a whole number (via Creme.int_value, so
    # this works even when the collapsed numerator doesn't fit Int64), so
    # a SchemeRational is never a whole number by construction (integer?,
    # eqv?, and display all lean on this elsewhere).
    def self.make(num : RatInt, den : RatInt) : SchemeValue
      raise SchemeRuntimeError.new("/: division by zero") if den == 0
      if den < 0
        num = Creme.rat_sub(0_i64, num)
        den = Creme.rat_sub(0_i64, den)
      end
      g = Creme.rat_gcd(num, den)
      num = Creme.int_div(num, g)
      den = Creme.int_div(den, g)
      num = Creme.rat_demote(num) if num.is_a?(BigInt)
      den = Creme.rat_demote(den) if den.is_a?(BigInt)
      den == 1 ? Creme.int_value(num) : new(num, den)
    end

    def to_display(io : IO) : Nil
      io << @numerator << '/' << @denominator
    end
  end

  # Exact (floor) division used only by SchemeRational.make's own
  # reduction, where the divisor (a gcd) is always positive and evenly
  # divides the dividend — a plain // works identically for Int64 or
  # BigInt operands.
  def self.int_div(a : RatInt, b : RatInt) : RatInt
    a.is_a?(Int64) && b.is_a?(Int64) ? a // b : to_big_i(a) // to_big_i(b)
  end
end
