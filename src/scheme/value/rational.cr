# ===========================================================================
# Exact rationals
#
# SchemeInt/SchemeRational/SchemeFloat form the numeric tower: SchemeInt and
# SchemeRational are exact, SchemeFloat is inexact. Numerator/denominator are
# plain Int64, matching SchemeInt's existing "machine-width, overflow raises
# SchemeRuntimeError" behavior rather than making rationals an inconsistent
# always-exact-never-overflows sibling type. BigInt is used only internally
# (never Scheme-visible) in a couple of narrow spots elsewhere (exact
# cross-multiplication comparison, inexact->exact conversion) where Int64
# would overflow mid-computation even though the final reduced result fits.
# ===========================================================================

module Scheme
  # Euclidean algorithm; always returns a non-negative result (R7RS: (gcd) is
  # 0, gcd is otherwise always >= 0 regardless of operand signs). This is the
  # single implementation shared by SchemeRational's internal reduction and
  # the public gcd/lcm builtins — never reimplemented at either call site.
  def self.int_gcd(a : Int64, b : Int64) : Int64
    a, b = a.abs, b.abs
    while b != 0
      a, b = b, a % b
    end
    a
  end

  def self.int_lcm(a : Int64, b : Int64) : Int64
    return 0_i64 if a == 0 || b == 0
    (a.abs // int_gcd(a, b)) * b.abs
  end

  # An exact non-integer rational. Never publicly constructed directly (see
  # SchemeRational.make) so "already reduced, positive denominator, never
  # denominator 1" is a structural guarantee, not a convention every call
  # site has to remember.
  class SchemeRational
    include SchemeBaseValue
    getter numerator : Int64
    getter denominator : Int64

    private def initialize(@numerator : Int64, @denominator : Int64)
    end

    # The only public constructor. Reduces to lowest terms and normalizes
    # the denominator to positive; returns a SchemeInt instead when the
    # ratio is actually a whole number, so a SchemeRational is never a
    # whole number by construction (integer?, eqv?, and display all lean on
    # this elsewhere).
    def self.make(num : Int64, den : Int64) : SchemeValue
      raise SchemeRuntimeError.new("/: division by zero") if den == 0
      if den < 0
        num = -num
        den = -den
      end
      g = Scheme.int_gcd(num, den)
      num //= g
      den //= g
      den == 1 ? SchemeInt.new(num) : new(num, den)
    end

    def to_display(io : IO) : Nil
      io << @numerator << '/' << @denominator
    end
  end
end
