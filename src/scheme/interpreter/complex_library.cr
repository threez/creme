# ===========================================================================
# (scheme complex)
# ===========================================================================
#
# Arithmetic promotion: num_add/num_sub/num_mul/divide (builtins.cr) check
# "is either operand complex?" FIRST and short-circuit to the helpers here
# if so, promoting the non-complex side to a zero-imaginary complex value —
# num_binop3's existing 3-way int/rational/float dispatch is untouched for
# the (overwhelmingly common) non-complex case, so this doesn't add a rank
# to that dispatcher or change its signature at all.

module Scheme
  class Interpreter
    SCHEME_COMPLEX_EXPORTS = %w[angle imag-part magnitude make-polar make-rectangular real-part complex?]

    private def install_complex_library : Nil
      env = Env.new
      install_complex(env)
      register_library(["scheme", "complex"], env, SCHEME_COMPLEX_EXPORTS.to_h { |name| {name, name} })
    end

    private def install_complex(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(SchemeValue) -> SchemeValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      reg.call("complex?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(number?(args[0])) })

      reg.call("make-rectangular", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        SchemeComplex.make(real_component_arg(args[0], "make-rectangular"), real_component_arg(args[1], "make-rectangular"))
      end)

      reg.call("make-polar", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        mag = Scheme.as_f64(args[0], "make-polar")
        ang = Scheme.as_f64(args[1], "make-polar")
        SchemeComplex.make(SchemeFloat.new(mag * Math.cos(ang)), SchemeFloat.new(mag * Math.sin(ang)))
      end)

      reg.call("real-part", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        v = args[0]
        v.is_a?(SchemeComplex) ? v.real.as(SchemeValue) : real_component_arg(v, "real-part").as(SchemeValue)
      end)

      reg.call("imag-part", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        v = args[0]
        v.is_a?(SchemeComplex) ? v.imag.as(SchemeValue) : SchemeInt.new(0_i64).as(SchemeValue)
      end)

      reg.call("magnitude", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        v = args[0]
        if v.is_a?(SchemeComplex)
          re, im = Scheme.as_f64(v.real, "magnitude"), Scheme.as_f64(v.imag, "magnitude")
          SchemeFloat.new(Math.sqrt(re*re + im*im)).as(SchemeValue)
        else
          apply(@base_env.get("abs"), [v]).as(SchemeValue)
        end
      end)

      reg.call("angle", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        v = args[0]
        if v.is_a?(SchemeComplex)
          SchemeFloat.new(Math.atan2(Scheme.as_f64(v.imag, "angle"), Scheme.as_f64(v.real, "angle"))).as(SchemeValue)
        else
          f = Scheme.as_f64(real_component_arg(v, "angle"), "angle")
          SchemeFloat.new(f < 0 ? Math::PI : 0.0).as(SchemeValue)
        end
      end)
    end

    private def real_component_arg(v : SchemeValue, who : String) : RealComponent
      case v
      when SchemeInt, SchemeRational, SchemeFloat then v
      else
        raise SchemeRuntimeError.new("#{who}: expected a real number, got #{v.write_string}")
      end
    end

    # Promotes a real numeric value to a zero-imaginary SchemeComplex, for
    # mixed complex/real arithmetic. Raises the normal "expected number"
    # error for anything non-numeric.
    private def to_complex(v : SchemeValue, who : String) : SchemeComplex
      return v if v.is_a?(SchemeComplex)
      SchemeComplex.wrap(real_component_arg(v, who), SchemeInt.new(0_i64))
    end

    private def complex_add(a : SchemeComplex, b : SchemeComplex, who : String) : SchemeValue
      SchemeComplex.make(num_add(a.real, b.real, who).as(RealComponent), num_add(a.imag, b.imag, who).as(RealComponent))
    end

    private def complex_sub(a : SchemeComplex, b : SchemeComplex, who : String) : SchemeValue
      SchemeComplex.make(num_sub(a.real, b.real, who).as(RealComponent), num_sub(a.imag, b.imag, who).as(RealComponent))
    end

    private def complex_mul(a : SchemeComplex, b : SchemeComplex, who : String) : SchemeValue
      # (a.re + a.im*i)(b.re + b.im*i) = (a.re*b.re - a.im*b.im) + (a.re*b.im + a.im*b.re)*i
      re = num_sub(num_mul(a.real, b.real, who), num_mul(a.imag, b.imag, who), who)
      im = num_add(num_mul(a.real, b.imag, who), num_mul(a.imag, b.real, who), who)
      SchemeComplex.make(re.as(RealComponent), im.as(RealComponent))
    end

    private def complex_div(a : SchemeComplex, b : SchemeComplex) : SchemeValue
      # a/b = a * conj(b) / |b|^2
      bre, bim = Scheme.as_f64(b.real, "/"), Scheme.as_f64(b.imag, "/")
      denom = bre*bre + bim*bim
      raise SchemeRuntimeError.new("/: division by zero") if denom == 0
      are, aim = Scheme.as_f64(a.real, "/"), Scheme.as_f64(a.imag, "/")
      SchemeComplex.make(SchemeFloat.new((are*bre + aim*bim) / denom), SchemeFloat.new((aim*bre - are*bim) / denom))
    end
  end
end
