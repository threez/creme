# ===========================================================================
# Complex numbers (R7RS (scheme complex))
#
# Real/imag components are always SchemeInt | SchemeBigInt | SchemeRational
# | SchemeFloat (never a nested SchemeComplex) — the numeric tower stays
# flat. Following SchemeRational's pattern: a private constructor plus a
# public .make that normalizes, collapsing to the bare real component when
# imag is exactly zero, so "is this genuinely complex" is answerable by
# type (v.is_a?(SchemeComplex)) rather than a scattered runtime imag==0
# check.
# ===========================================================================

module Creme
  alias RealComponent = SchemeInt | SchemeBigInt | SchemeRational | SchemeFloat

  class SchemeComplex
    include SchemeBaseValue
    getter real : RealComponent
    getter imag : RealComponent

    private def initialize(@real : RealComponent, @imag : RealComponent)
    end

    # The normalizing public constructor. Collapses to the bare real
    # component when imag is exactly zero AND exact (an inexact 0.0
    # imaginary part still makes an inexact complex result, per R7RS
    # contagion rules — (make-rectangular 1 0.0) is not simply 1).
    def self.make(real : RealComponent, imag : RealComponent) : SchemeValue
      return real if imag.is_a?(SchemeInt) && imag.value == 0
      new(real, imag)
    end

    # Always constructs a genuine SchemeComplex, bypassing .make's
    # collapse-to-real normalization — for internal use only, promoting a
    # real value to complex form for mixed arithmetic (see
    # Interpreter#to_complex in modules/scheme/complex.cr). The RESULT of the
    # arithmetic that follows is still routed back through .make, so
    # `1 + 0i` stays fully normalized end to end; only this intermediate
    # promotion step needs to skip the collapse.
    def self.wrap(real : RealComponent, imag : RealComponent) : SchemeComplex
      new(real, imag)
    end

    def to_display(io : IO) : Nil
      io << @real.display_string
      write_imag(io, @imag.display_string)
    end

    def to_write(io : IO) : Nil
      io << @real.write_string
      write_imag(io, @imag.write_string)
    end

    # A leading '-' (or the special "-inf.0"/"-nan.0" spellings) already
    # supplies its own sign, so only a non-negative-looking imaginary part
    # needs an explicit '+' inserted before it, per R7RS's a+bi/a-bi syntax.
    private def write_imag(io : IO, imag_text : String) : Nil
      io << '+' unless imag_text.starts_with?('-')
      io << imag_text << 'i'
    end
  end
end
