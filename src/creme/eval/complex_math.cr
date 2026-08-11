# ===========================================================================
# Pure (re, im) Float64 tuple formulas for the transcendentals that need to
# be complex-aware: sin/cos/tan/asin/acos/atan/exp/log/sqrt/expt. Deliberately
# untyped in terms of SchemeValue -- callers (math.cr, inexact.cr,
# arithmetic.cr) extract real/imag Float64 parts via
# BuiltinHelpers#complex_parts and rewrap via #complex_result. Same
# hand-rolled-over-two-doubles style as complex_div (builtin_helpers.cr) --
# no <complex.h>/C99 _Complex anywhere in this codebase.
# ===========================================================================

module Creme::ComplexMath
  extend self

  def add(ar, ai, br, bi)
    {ar + br, ai + bi}
  end

  def mul(ar, ai, br, bi)
    {ar*br - ai*bi, ar*bi + ai*br}
  end

  def div(ar, ai, br, bi)
    d = br*br + bi*bi
    {(ar*br + ai*bi) / d, (ai*br - ar*bi) / d}
  end

  def exp(re, im)
    e = Math.exp(re)
    {e*Math.cos(im), e*Math.sin(im)}
  end

  def log(re, im)
    {Math.log(Math.sqrt(re*re + im*im)), Math.atan2(im, re)}
  end

  def sqrt(re, im)
    r = Math.sqrt(re*re + im*im)
    sre = Math.sqrt((r + re) / 2)
    sim = Math.sqrt((r - re) / 2)
    {sre, im < 0 ? -sim : sim}
  end

  def sin(re, im)
    {Math.sin(re)*Math.cosh(im), Math.cos(re)*Math.sinh(im)}
  end

  def cos(re, im)
    {Math.cos(re)*Math.cosh(im), -Math.sin(re)*Math.sinh(im)}
  end

  def tan(re, im)
    sr, si = sin(re, im)
    cr, ci = cos(re, im)
    div(sr, si, cr, ci)
  end

  # asin(z) = -i * log(iz + sqrt(1 - z^2))
  def asin(re, im)
    z2r, z2i = mul(re, im, re, im)
    sr, si = sqrt(1.0 - z2r, -z2i)
    lr, li = log(-im + sr, re + si)
    {li, -lr}
  end

  # acos(z) = -i * log(z + i*sqrt(1 - z^2))
  def acos(re, im)
    z2r, z2i = mul(re, im, re, im)
    sr, si = sqrt(1.0 - z2r, -z2i)
    lr, li = log(re - si, im + sr)
    {li, -lr}
  end

  # atan(z) = (i/2) * log((1-iz)/(1+iz))
  def atan(re, im)
    qr, qi = div(1.0 + im, -re, 1.0 - im, re)
    lr, li = log(qr, qi)
    {-li/2.0, lr/2.0}
  end

  def pow(ar, ai, br, bi)
    return {0.0, 0.0} if ar == 0.0 && ai == 0.0
    lr, li = log(ar, ai)
    er, ei = mul(br, bi, lr, li)
    exp(er, ei)
  end
end
