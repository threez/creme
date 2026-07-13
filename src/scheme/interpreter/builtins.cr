# ===========================================================================
# Builtins
# ===========================================================================

require "big"

module Scheme
  class Interpreter
    # ameba:disable Metrics/CyclomaticComplexity
    private def install_builtins(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(SchemeValue) -> SchemeValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      # ---- Arithmetic ----
      reg.call("+", 0, -1, ->(args : Array(SchemeValue)) : SchemeValue do
        acc : SchemeValue = SchemeInt.new(0_i64)
        args.each { |arg| acc = num_add(acc, arg, "+") }
        acc
      end)

      reg.call("*", 0, -1, ->(args : Array(SchemeValue)) : SchemeValue do
        acc : SchemeValue = SchemeInt.new(1_i64)
        args.each { |arg| acc = num_mul(acc, arg, "*") }
        acc
      end)

      reg.call("-", 1, -1, ->(args : Array(SchemeValue)) : SchemeValue do
        if args.size == 1
          num_sub(SchemeInt.new(0_i64), args[0], "-")
        else
          acc = args[0]
          (1...args.size).each { |i| acc = num_sub(acc, args[i], "-") }
          acc
        end
      end)

      reg.call("/", 1, -1, ->(args : Array(SchemeValue)) : SchemeValue do
        if args.size == 1
          divide(SchemeInt.new(1_i64), args[0])
        else
          acc = args[0]
          (1...args.size).each { |i| acc = divide(acc, args[i]) }
          acc
        end
      end)

      reg.call("modulo", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        a = int_arg(args[0], "modulo")
        b = int_arg(args[1], "modulo")
        raise SchemeRuntimeError.new("modulo: division by zero") if b == 0
        begin
          SchemeInt.new(a % b)
        rescue ArgumentError | OverflowError
          raise SchemeRuntimeError.new("modulo: integer overflow")
        end
      end)

      reg.call("remainder", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        a = int_arg(args[0], "remainder")
        b = int_arg(args[1], "remainder")
        raise SchemeRuntimeError.new("remainder: division by zero") if b == 0
        SchemeInt.new(a.remainder(b))
      end)

      reg.call("quotient", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        a = int_arg(args[0], "quotient")
        b = int_arg(args[1], "quotient")
        raise SchemeRuntimeError.new("quotient: division by zero") if b == 0
        begin
          SchemeInt.new(a.tdiv(b)) # truncate toward zero
        rescue ArgumentError | OverflowError
          raise SchemeRuntimeError.new("quotient: integer overflow")
        end
      end)

      # truncate-quotient/truncate-remainder are exactly quotient/remainder
      # under R7RS's explicit names (both already truncate toward zero);
      # floor-quotient/floor-remainder match modulo's floor-toward-negative-
      # infinity rounding. The four /-suffixed procedures return both parts
      # at once via `values`.
      reg.call("truncate-quotient", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        apply(env.get("quotient"), args)
      end)

      reg.call("truncate-remainder", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        apply(env.get("remainder"), args)
      end)

      reg.call("floor-quotient", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        a = int_arg(args[0], "floor-quotient")
        b = int_arg(args[1], "floor-quotient")
        raise SchemeRuntimeError.new("floor-quotient: division by zero") if b == 0
        begin
          SchemeInt.new(a // b)
        rescue ArgumentError | OverflowError
          raise SchemeRuntimeError.new("floor-quotient: integer overflow")
        end
      end)

      reg.call("floor-remainder", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        apply(env.get("modulo"), args)
      end)

      reg.call("truncate/", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        SchemeValues.new([apply(env.get("truncate-quotient"), args), apply(env.get("truncate-remainder"), args)]).as(SchemeValue)
      end)

      reg.call("floor/", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        SchemeValues.new([apply(env.get("floor-quotient"), args), apply(env.get("floor-remainder"), args)]).as(SchemeValue)
      end)

      reg.call("abs", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        v = args[0]
        case v
        when SchemeInt
          begin
            SchemeInt.new(v.value.abs)
          rescue OverflowError
            raise SchemeRuntimeError.new("abs: integer overflow")
          end
        when SchemeFloat then SchemeFloat.new(v.value.abs)
        else                  raise SchemeRuntimeError.new("abs: expected number, got #{v.write_string}")
        end
      end)

      reg.call("min", 1, -1, ->(args : Array(SchemeValue)) : SchemeValue do
        fold_minmax(args, "min", true)
      end)

      reg.call("max", 1, -1, ->(args : Array(SchemeValue)) : SchemeValue do
        fold_minmax(args, "max", false)
      end)

      reg.call("gcd", 0, -1, ->(args : Array(SchemeValue)) : SchemeValue do
        result = args.reduce(0_i64) { |acc, v| Scheme.int_gcd(acc, int_arg(v, "gcd")) }
        SchemeInt.new(result).as(SchemeValue)
      end)

      reg.call("lcm", 0, -1, ->(args : Array(SchemeValue)) : SchemeValue do
        begin
          result = args.reduce(1_i64) { |acc, v| Scheme.int_lcm(acc, int_arg(v, "lcm")) }
          SchemeInt.new(result).as(SchemeValue)
        rescue OverflowError
          raise SchemeRuntimeError.new("lcm: integer overflow")
        end
      end)

      # (expt 2 -1) is now exact 1/2, not inexact 0.5: a negative integer
      # exponent of an exact integer base routes through the same positive-
      # exponent path (expt_int_pow) and SchemeRational.make, rather than
      # falling back to float power.
      reg.call("expt", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        base = args[0]
        ex = args[1]
        if base.is_a?(SchemeInt) && ex.is_a?(SchemeInt)
          if ex.value >= 0
            SchemeInt.new(expt_int_pow(base.value, ex.value))
          else
            begin
              SchemeRational.make(1_i64, expt_int_pow(base.value, -ex.value))
            rescue OverflowError
              raise SchemeRuntimeError.new("expt: integer overflow")
            end
          end
        else
          SchemeFloat.new(Scheme.as_f64(base, "expt") ** Scheme.as_f64(ex, "expt"))
        end
      end)

      # Exact perfect-square fast path ahead of the float fallback: (sqrt 4)
      # is now exact 2, not inexact 2.0. (sqrt 2) stays inexact (irrational,
      # no exact representation). Shares its integer-sqrt logic with the
      # exact-integer-sqrt builtin below rather than duplicating it.
      reg.call("sqrt", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        v = args[0]
        if v.is_a?(SchemeInt) && v.value >= 0
          root, rem = exact_integer_sqrt_pair(v.value)
          rem == 0 ? SchemeInt.new(root).as(SchemeValue) : SchemeFloat.new(Math.sqrt(Scheme.as_f64(v, "sqrt"))).as(SchemeValue)
        elsif number?(v) && !v.is_a?(SchemeComplex) && Scheme.as_f64(v, "sqrt") < 0
          # sqrt of a negative real is complex, per R7RS — the magnitude's
          # square root goes on the imaginary axis.
          SchemeComplex.make(SchemeFloat.new(0.0), SchemeFloat.new(Math.sqrt(-Scheme.as_f64(v, "sqrt")))).as(SchemeValue)
        else
          SchemeFloat.new(Math.sqrt(Scheme.as_f64(v, "sqrt")))
        end
      end)

      reg.call("exact-integer-sqrt", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        n = int_arg(args[0], "exact-integer-sqrt")
        raise SchemeRuntimeError.new("exact-integer-sqrt: expected a non-negative integer") if n < 0
        root, rem = exact_integer_sqrt_pair(n)
        SchemeValues.new([SchemeInt.new(root).as(SchemeValue), SchemeInt.new(rem).as(SchemeValue)])
      end)

      # ---- Exactness conversions ----
      reg.call("inexact", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeFloat.new(Scheme.as_f64(args[0], "inexact")) })
      reg.call("exact", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { to_exact(args[0]) })

      # On a float, round-trips through the exact equivalent (per R7RS):
      # (numerator 2.5) is 5.0, (denominator 2.5) is 2.0 — both stay inexact.
      reg.call("numerator", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        v = args[0]
        case v
        when SchemeInt      then v.as(SchemeValue)
        when SchemeRational then SchemeInt.new(v.numerator).as(SchemeValue)
        when SchemeFloat
          n, _ = Scheme.as_ratio(to_exact(v))
          SchemeFloat.new(n.to_f64).as(SchemeValue)
        else raise SchemeRuntimeError.new("numerator: expected number, got #{v.write_string}")
        end
      end)

      reg.call("denominator", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        v = args[0]
        case v
        when SchemeInt      then SchemeInt.new(1_i64).as(SchemeValue)
        when SchemeRational then SchemeInt.new(v.denominator).as(SchemeValue)
        when SchemeFloat
          _, d = Scheme.as_ratio(to_exact(v))
          SchemeFloat.new(d.to_f64).as(SchemeValue)
        else raise SchemeRuntimeError.new("denominator: expected number, got #{v.write_string}")
        end
      end)

      # R7RS's floor/ceiling/truncate/round are generic over the numeric
      # tower: an exact (integer) argument returns itself exactly, an
      # inexact (float) argument is rounded and stays inexact.
      reg.call("floor", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { round_like(args[0], "floor", ->rational_floor(Int64, Int64), &.floor) })
      reg.call("ceiling", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { round_like(args[0], "ceiling", ->rational_ceiling(Int64, Int64), &.ceil) })
      reg.call("truncate", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { round_like(args[0], "truncate", ->rational_truncate(Int64, Int64), &.trunc) })
      reg.call("round", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { round_like(args[0], "round", ->rational_round(Int64, Int64), &.round(:ties_even)) })

      # ---- Comparisons ----
      reg.call("=", 1, -1, ->(args : Array(SchemeValue)) : SchemeValue { num_chain(args, "=") { |cmp| cmp == 0 } })
      reg.call("<", 1, -1, ->(args : Array(SchemeValue)) : SchemeValue { num_chain(args, "<") { |cmp| cmp < 0 } })
      reg.call(">", 1, -1, ->(args : Array(SchemeValue)) : SchemeValue { num_chain(args, ">") { |cmp| cmp > 0 } })
      reg.call("<=", 1, -1, ->(args : Array(SchemeValue)) : SchemeValue { num_chain(args, "<=") { |cmp| cmp <= 0 } })
      reg.call(">=", 1, -1, ->(args : Array(SchemeValue)) : SchemeValue { num_chain(args, ">=") { |cmp| cmp >= 0 } })

      reg.call("not", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(!Scheme.truthy?(args[0])) })

      reg.call("eq?", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(Scheme.scheme_eqv?(args[0], args[1])) })
      reg.call("eqv?", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(Scheme.scheme_eqv?(args[0], args[1])) })
      reg.call("equal?", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(Scheme.scheme_equal?(args[0], args[1])) })

      # ---- Pairs & lists ----
      reg.call("cons", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue { Cons.new(args[0], args[1]).as(SchemeValue) })

      reg.call("car", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        v = args[0]
        raise SchemeRuntimeError.new("car: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
        v.car
      end)

      reg.call("cdr", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        v = args[0]
        raise SchemeRuntimeError.new("cdr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
        v.cdr
      end)

      reg.call("set-car!", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        v = args[0]
        raise SchemeRuntimeError.new("set-car!: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
        v.car = args[1]
        NIL.as(SchemeValue)
      end)

      reg.call("set-cdr!", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        v = args[0]
        raise SchemeRuntimeError.new("set-cdr!: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
        v.cdr = args[1]
        NIL.as(SchemeValue)
      end)

      reg.call("list", 0, -1, ->(args : Array(SchemeValue)) : SchemeValue { Scheme.a_to_list(args) })

      reg.call("append", 0, -1, ->(args : Array(SchemeValue)) : SchemeValue do
        return NIL.as(SchemeValue) if args.empty?
        result = args[args.size - 1]
        i = args.size - 2
        while i >= 0
          elems = Scheme.list_to_a(args[i])
          result = Scheme.a_to_list(elems, result)
          i -= 1
        end
        result
      end)

      reg.call("length", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        SchemeInt.new(Scheme.list_to_a(args[0]).size.to_i64)
      end)

      reg.call("reverse", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        elems = Scheme.list_to_a(args[0])
        Scheme.a_to_list(elems.reverse)
      end)

      reg.call("list-ref", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        elems = Scheme.list_to_a(args[0])
        idx = int_arg(args[1], "list-ref")
        if idx < 0 || idx >= elems.size
          raise SchemeRuntimeError.new("list-ref: index #{idx} out of range")
        end
        elems[idx]
      end)

      reg.call("null?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(args[0].is_a?(SchemeNil)) })
      reg.call("pair?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(args[0].is_a?(Cons)) })
      reg.call("list?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(Scheme.proper_list?(args[0])) })

      reg.call("list-copy", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        v = args[0]
        v.is_a?(Cons) ? Scheme.a_to_list(Scheme.list_to_a(v)) : v
      end)

      reg.call("list-set!", 3, 3, ->(args : Array(SchemeValue)) : SchemeValue do
        idx = int_arg(args[1], "list-set!")
        raise SchemeRuntimeError.new("list-set!: index #{idx} out of range") if idx < 0
        cur = args[0]
        idx.times do
          raise SchemeRuntimeError.new("list-set!: index out of range") unless cur.is_a?(Cons)
          cur = cur.cdr
        end
        raise SchemeRuntimeError.new("list-set!: index out of range") unless cur.is_a?(Cons)
        cur.car = args[2]
        NIL.as(SchemeValue)
      end)

      reg.call("list-tail", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        idx = int_arg(args[1], "list-tail")
        raise SchemeRuntimeError.new("list-tail: index #{idx} out of range") if idx < 0
        cur = args[0]
        idx.times do
          raise SchemeRuntimeError.new("list-tail: index out of range") unless cur.is_a?(Cons)
          cur = cur.cdr
        end
        cur
      end)

      reg.call("make-list", 1, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        n = int_arg(args[0], "make-list")
        raise SchemeRuntimeError.new("make-list: expected a non-negative length") if n < 0
        fill = args[1]? || NIL
        Scheme.a_to_list(Array.new(n.to_i32, fill))
      end)

      # assq/assv/memq/memv use eq?/eqv? identity comparison; assoc/member
      # default to equal? but accept an optional comparator procedure.
      reg.call("assq", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue { assoc_impl(args[0], args[1], nil, use_eqv: true) })
      reg.call("assv", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue { assoc_impl(args[0], args[1], nil, use_eqv: true) })
      reg.call("assoc", 2, 3, ->(args : Array(SchemeValue)) : SchemeValue { assoc_impl(args[0], args[1], args[2]?, use_eqv: false) })

      reg.call("memq", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue { member_impl(args[0], args[1], nil, use_eqv: true) })
      reg.call("memv", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue { member_impl(args[0], args[1], nil, use_eqv: true) })
      reg.call("member", 2, 3, ->(args : Array(SchemeValue)) : SchemeValue { member_impl(args[0], args[1], args[2]?, use_eqv: false) })

      # ---- Vectors ----
      reg.call("vector", 0, -1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeVector.new(args.dup) })

      reg.call("make-vector", 1, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        n = vector_index_arg(args[0], "make-vector")
        raise SchemeRuntimeError.new("make-vector: size must be non-negative") if n < 0
        fill = args.size == 2 ? args[1] : NIL.as(SchemeValue)
        SchemeVector.new(Array.new(n) { fill })
      end)

      reg.call("vector-ref", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        v = vector_arg(args[0], "vector-ref")
        i = vector_index_arg(args[1], "vector-ref")
        raise SchemeRuntimeError.new("vector-ref: index #{i} out of range") if i < 0 || i >= v.size
        v[i]
      end)

      reg.call("vector-set!", 3, 3, ->(args : Array(SchemeValue)) : SchemeValue do
        v = vector_arg(args[0], "vector-set!")
        i = vector_index_arg(args[1], "vector-set!")
        raise SchemeRuntimeError.new("vector-set!: index #{i} out of range") if i < 0 || i >= v.size
        v[i] = args[2]
        NIL.as(SchemeValue)
      end)

      reg.call("vector-length", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        SchemeInt.new(vector_arg(args[0], "vector-length").size.to_i64)
      end)

      reg.call("vector?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(args[0].is_a?(SchemeVector)) })

      reg.call("vector->list", 1, 3, ->(args : Array(SchemeValue)) : SchemeValue do
        elems = vector_arg(args[0], "vector->list")
        first, last = seq_range_args(elems.size, args[1]?, args[2]?, "vector->list")
        Scheme.a_to_list(elems[first...last])
      end)

      reg.call("list->vector", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        SchemeVector.new(Scheme.list_to_a(args[0]))
      end)

      reg.call("vector-map", 2, -1, ->(args : Array(SchemeValue)) : SchemeValue do
        f = args[0]
        vectors = args[1..].map { |v| vector_arg(v, "vector-map") }
        minlen = vectors.min_of(&.size)
        result = Array(SchemeValue).new(minlen) { NIL }
        minlen.times do |i|
          call_args = vectors.map { |elems| elems[i] }
          result[i] = apply(f, call_args)
        end
        SchemeVector.new(result)
      end)

      reg.call("vector-for-each", 2, -1, ->(args : Array(SchemeValue)) : SchemeValue do
        f = args[0]
        vectors = args[1..].map { |v| vector_arg(v, "vector-for-each") }
        minlen = vectors.min_of(&.size)
        minlen.times do |i|
          call_args = vectors.map { |elems| elems[i] }
          apply(f, call_args)
        end
        NIL.as(SchemeValue)
      end)

      reg.call("vector-copy", 1, 3, ->(args : Array(SchemeValue)) : SchemeValue do
        elems = vector_arg(args[0], "vector-copy")
        first, last = seq_range_args(elems.size, args[1]?, args[2]?, "vector-copy")
        SchemeVector.new(elems[first...last])
      end)

      reg.call("vector-copy!", 3, 5, ->(args : Array(SchemeValue)) : SchemeValue do
        to = vector_arg(args[0], "vector-copy!")
        at = int_arg(args[1], "vector-copy!").to_i32
        from = vector_arg(args[2], "vector-copy!")
        first, last = seq_range_args(from.size, args[3]?, args[4]?, "vector-copy!")
        segment = from[first...last]
        raise SchemeRuntimeError.new("vector-copy!: destination range out of bounds") if at < 0 || at + segment.size > to.size
        segment.each_with_index { |v, i| to[at + i] = v }
        NIL.as(SchemeValue)
      end)

      reg.call("vector-fill!", 2, 4, ->(args : Array(SchemeValue)) : SchemeValue do
        elems = vector_arg(args[0], "vector-fill!")
        fill = args[1]
        first, last = seq_range_args(elems.size, args[2]?, args[3]?, "vector-fill!")
        (first...last).each { |i| elems[i] = fill }
        NIL.as(SchemeValue)
      end)

      reg.call("vector-append", 0, -1, ->(args : Array(SchemeValue)) : SchemeValue do
        result = [] of SchemeValue
        args.each { |v| result.concat(vector_arg(v, "vector-append")) }
        SchemeVector.new(result)
      end)

      # ---- Higher-order ----
      reg.call("map", 2, -1, ->(args : Array(SchemeValue)) : SchemeValue do
        f = args[0]
        lists = args[1..-1].map { |list| Scheme.list_to_a(list) }
        minlen = lists.min_of(&.size)
        acc = [] of SchemeValue
        (0...minlen).each do |i|
          call_args = lists.map { |list| list[i] }
          acc << apply(f, call_args)
        end
        Scheme.a_to_list(acc)
      end)

      reg.call("for-each", 2, -1, ->(args : Array(SchemeValue)) : SchemeValue do
        f = args[0]
        lists = args[1..-1].map { |list| Scheme.list_to_a(list) }
        minlen = lists.min_of(&.size)
        (0...minlen).each do |i|
          call_args = lists.map { |list| list[i] }
          apply(f, call_args)
        end
        NIL.as(SchemeValue)
      end)

      reg.call("apply", 2, -1, ->(args : Array(SchemeValue)) : SchemeValue do
        f = args[0]
        middle = args[1...args.size - 1]
        last = args[args.size - 1]
        call_args = middle + Scheme.list_to_a(last)
        apply(f, call_args)
      end)

      reg.call("eval", 1, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        target_env = args.size == 2 ? environment_specifier_arg(args[1], "eval") : @global
        eval(args[0], target_env)
      end)

      # (environment list...) — a fresh, otherwise-empty Env populated by
      # importing each list as an import set (the same grammar/mechanism
      # eval_import uses for a program's own top-level import declarations).
      # The resulting environment specifier's bindings are immutable in the
      # sense that R7RS describes (this implementation doesn't separately
      # enforce that; nothing here differs from any other Env in practice).
      reg.call("environment", 0, -1, ->(args : Array(SchemeValue)) : SchemeValue do
        target_env = Env.new
        args.each { |import_set| import_into(target_env, import_set) }
        SchemeEnvironment.new(target_env)
      end)

      # (null-environment version) — an environment with only the syntactic
      # keywords bound, no procedures. `version` (5, matching R5RS) is
      # accepted but otherwise unused, per R7RS's own description of this
      # procedure existing for R5RS-compatibility purposes.
      reg.call("null-environment", 0, 1, ->(_args : Array(SchemeValue)) : SchemeValue do
        target_env = Env.new
        install_special_forms(target_env)
        SchemeEnvironment.new(target_env)
      end)

      # (scheme-report-environment version) — an environment containing the
      # R5RS-report bindings. This implementation doesn't maintain a
      # separate R5RS-vs-R7RS binding set, so, like null-environment, this
      # wraps @base_env (the same bindings (scheme base) itself wraps).
      reg.call("scheme-report-environment", 0, 1, ->(_args : Array(SchemeValue)) : SchemeValue do
        SchemeEnvironment.new(@base_env)
      end)

      # (interaction-environment) — a specifier for the environment a REPL
      # would evaluate typed-in expressions against, i.e. @global itself.
      reg.call("interaction-environment", 0, 0, ->(_args : Array(SchemeValue)) : SchemeValue do
        SchemeEnvironment.new(@global)
      end)

      # (values x) is x itself, not a wrapped single-element SchemeValues —
      # `values` is transparent outside call-with-values, per R7RS.
      reg.call("values", 0, -1, ->(args : Array(SchemeValue)) : SchemeValue do
        args.size == 1 ? args[0] : SchemeValues.new(args).as(SchemeValue)
      end)

      reg.call("call-with-values", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        producer, consumer = args[0], args[1]
        result = apply(producer, [] of SchemeValue)
        call_args = result.is_a?(SchemeValues) ? result.items : [result]
        apply(consumer, call_args)
      end)

      # call/cc: escape continuations only (non-local exit / early return /
      # guard-style unwinding), not full R7RS multi-shot re-entrant
      # continuations — see call_cc's doc comment for the mechanism and its
      # limits.
      reg.call("call/cc", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { call_cc(args[0]) })
      reg.call("call-with-current-continuation", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { call_cc(args[0]) })

      # (dynamic-wind before thunk after): before/after always run in pairs
      # around thunk, even when thunk escapes via a call/cc continuation,
      # an uncaught SchemeError, or (exit ...) — Crystal's `ensure` doesn't
      # discriminate the unwind's cause, so after always fires. Since
      # call/cc here is escape-only (see call_cc's own doc comment), what
      # this does NOT provide is R7RS's full requirement that `before`
      # re-fires when a continuation captured INSIDE this dynamic-wind is
      # later invoked to re-enter it from OUTSIDE, after dynamic-wind
      # itself already returned — that needs true re-entrant continuations.
      # Invoking such a continuation here instead raises the existing
      # "continuation invoked outside its dynamic extent" error (see
      # call_cc/apply's SchemeContinuation arm) rather than behaving
      # incorrectly.
      reg.call("dynamic-wind", 3, 3, ->(args : Array(SchemeValue)) : SchemeValue do
        before, thunk, after = args[0], args[1], args[2]
        apply(before, [] of SchemeValue)
        begin
          apply(thunk, [] of SchemeValue)
        ensure
          apply(after, [] of SchemeValue)
        end
      end)

      # ---- Type predicates ----
      reg.call("number?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(number?(args[0])) })
      # real? is number? minus genuine complex values (a SchemeComplex is
      # never real by construction — SchemeComplex.make collapses an exact
      # zero imaginary part back to a bare real component).
      reg.call("real?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(number?(args[0]) && !args[0].is_a?(SchemeComplex)) })
      # rational? is number? minus the non-finite floats (+inf.0/-inf.0/+nan.0).
      reg.call("rational?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        v = args[0]
        SchemeBool.of(Scheme.exact?(v) || (v.is_a?(SchemeFloat) && v.value.finite?))
      end)
      # integer? is about numeric VALUE, not representation: a whole-valued
      # float like 3.0 is an integer per R7RS. A SchemeRational is never a
      # whole number by construction (SchemeRational.make always collapses
      # those to SchemeInt), so its case is always false.
      reg.call("integer?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        v = args[0]
        is_int =
          case v
          when SchemeInt      then true
          when SchemeRational then false
          when SchemeFloat    then v.value.finite? && v.value == v.value.to_i64.to_f64
          else                     false
          end
        SchemeBool.of(is_int)
      end)
      reg.call("exact-integer?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(args[0].is_a?(SchemeInt)) })
      reg.call("exact?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(Scheme.exact?(args[0])) })
      reg.call("inexact?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(Scheme.inexact?(args[0])) })

      reg.call("nan?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        v = args[0]
        SchemeBool.of(v.is_a?(SchemeFloat) && v.value.nan?)
      end)
      reg.call("infinite?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        v = args[0]
        SchemeBool.of(v.is_a?(SchemeFloat) && v.value.infinite? != nil)
      end)
      reg.call("finite?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        v = args[0]
        SchemeBool.of(!v.is_a?(SchemeFloat) || v.value.finite?)
      end)

      reg.call("square", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { num_mul(args[0], args[0], "square") })
      reg.call("symbol?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(args[0].is_a?(SchemeSym)) })
      reg.call("string?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(args[0].is_a?(SchemeStr)) })
      reg.call("boolean?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(args[0].is_a?(SchemeBool)) })
      reg.call("char?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(args[0].is_a?(SchemeChar)) })
      reg.call("procedure?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(args[0].is_a?(Builtin) || args[0].is_a?(Lambda) || args[0].is_a?(CaseLambda)) })
      reg.call("macro?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(args[0].is_a?(Macro)) })

      # ---- Strings & conversion ----
      reg.call("string-append", 0, -1, ->(args : Array(SchemeValue)) : SchemeValue do
        buf = String::Builder.new
        args.each do |arg|
          raise SchemeRuntimeError.new("string-append: expected string, got #{arg.write_string}") unless arg.is_a?(SchemeStr)
          buf << arg.value
        end
        SchemeStr.new(buf.to_s)
      end)

      reg.call("string-length", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        s = args[0]
        raise SchemeRuntimeError.new("string-length: expected string, got #{s.write_string}") unless s.is_a?(SchemeStr)
        SchemeInt.new(s.value.size.to_i64)
      end)

      reg.call("substring", 2, 3, ->(args : Array(SchemeValue)) : SchemeValue do
        s = args[0]
        raise SchemeRuntimeError.new("substring: expected string, got #{s.write_string}") unless s.is_a?(SchemeStr)
        len = s.value.size.to_i64
        start64 = int_arg(args[1], "substring")
        endi64 = args.size == 3 ? int_arg(args[2], "substring") : len
        if start64 < 0 || endi64 > len || start64 > endi64
          raise SchemeRuntimeError.new("substring: index out of range")
        end
        SchemeStr.new(s.value[start64.to_i...endi64.to_i])
      end)

      reg.call("string->symbol", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        s = args[0]
        raise SchemeRuntimeError.new("string->symbol: expected string, got #{s.write_string}") unless s.is_a?(SchemeStr)
        SchemeSym.of(s.value)
      end)

      reg.call("symbol->string", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        s = args[0]
        raise SchemeRuntimeError.new("symbol->string: expected symbol, got #{s.write_string}") unless s.is_a?(SchemeSym)
        SchemeStr.new(s.name)
      end)

      reg.call("symbol=?", 2, -1, ->(args : Array(SchemeValue)) : SchemeValue do
        first = args[0]
        raise SchemeRuntimeError.new("symbol=?: expected symbol, got #{first.write_string}") unless first.is_a?(SchemeSym)
        (1...args.size).each do |i|
          other = args[i]
          raise SchemeRuntimeError.new("symbol=?: expected symbol, got #{other.write_string}") unless other.is_a?(SchemeSym)
          return FALSE.as(SchemeValue) unless other.name == first.name
        end
        TRUE.as(SchemeValue)
      end)

      reg.call("boolean=?", 2, -1, ->(args : Array(SchemeValue)) : SchemeValue do
        first = args[0]
        raise SchemeRuntimeError.new("boolean=?: expected boolean, got #{first.write_string}") unless first.is_a?(SchemeBool)
        (1...args.size).each do |i|
          other = args[i]
          raise SchemeRuntimeError.new("boolean=?: expected boolean, got #{other.write_string}") unless other.is_a?(SchemeBool)
          return FALSE.as(SchemeValue) unless other.value? == first.value?
        end
        TRUE.as(SchemeValue)
      end)

      # radix (default 10) only applies to exact integers — R7RS leaves
      # non-decimal radix on inexact/non-integer numbers unspecified, so a
      # radix other than 10 is rejected for anything but a SchemeInt here.
      reg.call("number->string", 1, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        n = args[0]
        radix = radix_arg(args[1]?, "number->string")
        unless n.is_a?(SchemeInt) || n.is_a?(SchemeRational) || n.is_a?(SchemeFloat)
          raise SchemeRuntimeError.new("number->string: expected number, got #{n.write_string}")
        end
        if radix == 10
          SchemeStr.new(n.display_string)
        else
          raise SchemeRuntimeError.new("number->string: radix #{radix} requires an exact integer") unless n.is_a?(SchemeInt)
          SchemeStr.new(n.value.to_s(radix))
        end
      end)

      reg.call("string->number", 1, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        s = args[0]
        radix = radix_arg(args[1]?, "string->number")
        raise SchemeRuntimeError.new("string->number: expected string, got #{s.write_string}") unless s.is_a?(SchemeStr)
        parse_number_string(s.value, radix)
      end)

      reg.call("string=?", 2, -1, ->(args : Array(SchemeValue)) : SchemeValue do
        first = args[0]
        raise SchemeRuntimeError.new("string=?: expected string, got #{first.write_string}") unless first.is_a?(SchemeStr)
        (1...args.size).each do |i|
          s = args[i]
          raise SchemeRuntimeError.new("string=?: expected string, got #{s.write_string}") unless s.is_a?(SchemeStr)
          return FALSE.as(SchemeValue) unless s.value == first.value
        end
        TRUE.as(SchemeValue)
      end)

      reg.call("string<?", 2, -1, ->(args : Array(SchemeValue)) : SchemeValue { string_chain_cmp(args, "string<?") { |lhs, rhs| lhs < rhs } })
      reg.call("string>?", 2, -1, ->(args : Array(SchemeValue)) : SchemeValue { string_chain_cmp(args, "string>?") { |lhs, rhs| lhs > rhs } })
      reg.call("string<=?", 2, -1, ->(args : Array(SchemeValue)) : SchemeValue { string_chain_cmp(args, "string<=?") { |lhs, rhs| lhs <= rhs } })
      reg.call("string>=?", 2, -1, ->(args : Array(SchemeValue)) : SchemeValue { string_chain_cmp(args, "string>=?") { |lhs, rhs| lhs >= rhs } })

      reg.call("string-foldcase", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        s = args[0]
        raise SchemeRuntimeError.new("string-foldcase: expected string, got #{s.write_string}") unless s.is_a?(SchemeStr)
        SchemeStr.new(s.value.downcase)
      end)

      reg.call("string-ci=?", 2, -1, ->(args : Array(SchemeValue)) : SchemeValue { string_chain_cmp(args, "string-ci=?") { |lhs, rhs| lhs.downcase == rhs.downcase } })
      reg.call("string-ci<?", 2, -1, ->(args : Array(SchemeValue)) : SchemeValue { string_chain_cmp(args, "string-ci<?") { |lhs, rhs| lhs.downcase < rhs.downcase } })
      reg.call("string-ci>?", 2, -1, ->(args : Array(SchemeValue)) : SchemeValue { string_chain_cmp(args, "string-ci>?") { |lhs, rhs| lhs.downcase > rhs.downcase } })
      reg.call("string-ci<=?", 2, -1, ->(args : Array(SchemeValue)) : SchemeValue { string_chain_cmp(args, "string-ci<=?") { |lhs, rhs| lhs.downcase <= rhs.downcase } })
      reg.call("string-ci>=?", 2, -1, ->(args : Array(SchemeValue)) : SchemeValue { string_chain_cmp(args, "string-ci>=?") { |lhs, rhs| lhs.downcase >= rhs.downcase } })

      reg.call("string-ref", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        s = args[0]
        raise SchemeRuntimeError.new("string-ref: expected string, got #{s.write_string}") unless s.is_a?(SchemeStr)
        idx = int_arg(args[1], "string-ref")
        raise SchemeRuntimeError.new("string-ref: index out of range") if idx < 0 || idx >= s.value.size
        SchemeChar.new(s.value[idx.to_i])
      end)

      reg.call("string->list", 1, 3, ->(args : Array(SchemeValue)) : SchemeValue do
        s = string_arg(args[0], "string->list")
        chars = s.chars
        first, last = seq_range_args(chars.size, args[1]?, args[2]?, "string->list")
        Scheme.a_to_list(chars[first...last].map { |chr| SchemeChar.new(chr).as(SchemeValue) })
      end)

      reg.call("list->string", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        buf = String::Builder.new
        Scheme.list_to_a(args[0]).each do |v|
          raise SchemeRuntimeError.new("list->string: expected list of chars, got #{v.write_string}") unless v.is_a?(SchemeChar)
          buf << v.value
        end
        SchemeStr.new(buf.to_s)
      end)

      reg.call("string", 0, -1, ->(args : Array(SchemeValue)) : SchemeValue do
        buf = String::Builder.new
        args.each do |v|
          raise SchemeRuntimeError.new("string: expected char, got #{v.write_string}") unless v.is_a?(SchemeChar)
          buf << v.value
        end
        SchemeStr.new(buf.to_s)
      end)

      reg.call("string-map", 2, -1, ->(args : Array(SchemeValue)) : SchemeValue do
        f = args[0]
        strings = args[1..].map { |v| string_arg(v, "string-map").chars }
        minlen = strings.min_of(&.size)
        buf = String::Builder.new
        minlen.times do |i|
          call_args = strings.map { |chars| SchemeChar.new(chars[i]).as(SchemeValue) }
          result = apply(f, call_args)
          raise SchemeRuntimeError.new("string-map: expected the function to return a char") unless result.is_a?(SchemeChar)
          buf << result.value
        end
        SchemeStr.new(buf.to_s)
      end)

      reg.call("string-for-each", 2, -1, ->(args : Array(SchemeValue)) : SchemeValue do
        f = args[0]
        strings = args[1..].map { |v| string_arg(v, "string-for-each").chars }
        minlen = strings.min_of(&.size)
        minlen.times do |i|
          call_args = strings.map { |chars| SchemeChar.new(chars[i]).as(SchemeValue) }
          apply(f, call_args)
        end
        NIL.as(SchemeValue)
      end)

      reg.call("string-copy", 1, 3, ->(args : Array(SchemeValue)) : SchemeValue do
        s = string_arg(args[0], "string-copy")
        first, last = seq_range_args(s.size, args[1]?, args[2]?, "string-copy")
        SchemeStr.new(s[first...last])
      end)

      # (string-copy! to at from [start [end]]) copies from[start...end]
      # into to, starting at index `at`. Since Crystal strings are
      # immutable, this rebuilds `to`'s whole backing String rather than
      # mutating in place.
      reg.call("string-copy!", 3, 5, ->(args : Array(SchemeValue)) : SchemeValue do
        to = args[0]
        raise SchemeRuntimeError.new("string-copy!: expected string, got #{to.write_string}") unless to.is_a?(SchemeStr)
        at = int_arg(args[1], "string-copy!").to_i32
        from = string_arg(args[2], "string-copy!")
        first, last = seq_range_args(from.size, args[3]?, args[4]?, "string-copy!")
        segment = from[first...last]
        to_chars = to.value.chars
        raise SchemeRuntimeError.new("string-copy!: destination range out of bounds") if at < 0 || at + segment.size > to_chars.size
        to_chars[at, segment.size] = segment.chars
        to.value = to_chars.join
        NIL.as(SchemeValue)
      end)

      reg.call("string-set!", 3, 3, ->(args : Array(SchemeValue)) : SchemeValue do
        s = args[0]
        raise SchemeRuntimeError.new("string-set!: expected string, got #{s.write_string}") unless s.is_a?(SchemeStr)
        idx = int_arg(args[1], "string-set!").to_i32
        ch = args[2]
        raise SchemeRuntimeError.new("string-set!: expected char, got #{ch.write_string}") unless ch.is_a?(SchemeChar)
        chars = s.value.chars
        raise SchemeRuntimeError.new("string-set!: index out of range") if idx < 0 || idx >= chars.size
        chars[idx] = ch.value
        s.value = chars.join
        NIL.as(SchemeValue)
      end)

      reg.call("string-fill!", 2, 4, ->(args : Array(SchemeValue)) : SchemeValue do
        s = args[0]
        raise SchemeRuntimeError.new("string-fill!: expected string, got #{s.write_string}") unless s.is_a?(SchemeStr)
        fill = args[1]
        raise SchemeRuntimeError.new("string-fill!: expected char, got #{fill.write_string}") unless fill.is_a?(SchemeChar)
        chars = s.value.chars
        first, last = seq_range_args(chars.size, args[2]?, args[3]?, "string-fill!")
        (first...last).each { |i| chars[i] = fill.value }
        s.value = chars.join
        NIL.as(SchemeValue)
      end)

      reg.call("string->vector", 1, 3, ->(args : Array(SchemeValue)) : SchemeValue do
        s = string_arg(args[0], "string->vector")
        chars = s.chars
        first, last = seq_range_args(chars.size, args[1]?, args[2]?, "string->vector")
        SchemeVector.new(chars[first...last].map { |chr| SchemeChar.new(chr).as(SchemeValue) })
      end)

      reg.call("vector->string", 1, 3, ->(args : Array(SchemeValue)) : SchemeValue do
        elems = vector_arg(args[0], "vector->string")
        first, last = seq_range_args(elems.size, args[1]?, args[2]?, "vector->string")
        buf = String::Builder.new
        elems[first...last].each do |v|
          raise SchemeRuntimeError.new("vector->string: expected vector of chars, got #{v.write_string}") unless v.is_a?(SchemeChar)
          buf << v.value
        end
        SchemeStr.new(buf.to_s)
      end)

      reg.call("make-string", 1, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        len = int_arg(args[0], "make-string")
        raise SchemeRuntimeError.new("make-string: length must be non-negative") if len < 0
        fill = ' '
        if args.size == 2
          f = args[1]
          raise SchemeRuntimeError.new("make-string: expected char, got #{f.write_string}") unless f.is_a?(SchemeChar)
          fill = f.value
        end
        SchemeStr.new(fill.to_s * len)
      end)

      reg.call("char->integer", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        c = args[0]
        raise SchemeRuntimeError.new("char->integer: expected char, got #{c.write_string}") unless c.is_a?(SchemeChar)
        SchemeInt.new(c.value.ord.to_i64)
      end)

      reg.call("integer->char", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        n = int_arg(args[0], "integer->char")
        raise SchemeRuntimeError.new("integer->char: code point out of range") if n < 0 || n > 0x10FFFF
        SchemeChar.new(n.to_i32.chr)
      end)

      reg.call("char-upcase", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeChar.new(char_arg(args[0], "char-upcase").upcase) })
      reg.call("char-downcase", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeChar.new(char_arg(args[0], "char-downcase").downcase) })
      # foldcase is what case-insensitive comparisons use internally in a
      # full Unicode-aware implementation; here it's the same as downcase,
      # which is correct for the ASCII/simple-Unicode range this interpreter
      # otherwise handles.
      reg.call("char-foldcase", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeChar.new(char_arg(args[0], "char-foldcase").downcase) })

      reg.call("digit-value", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        c = char_arg(args[0], "digit-value")
        n = c.to_i?
        n ? SchemeInt.new(n.to_i64).as(SchemeValue) : FALSE.as(SchemeValue)
      end)

      reg.call("char-alphabetic?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(char_arg(args[0], "char-alphabetic?").letter?) })
      reg.call("char-numeric?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(char_arg(args[0], "char-numeric?").number?) })
      reg.call("char-whitespace?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(char_arg(args[0], "char-whitespace?").whitespace?) })
      reg.call("char-upper-case?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(char_arg(args[0], "char-upper-case?").uppercase?) })
      reg.call("char-lower-case?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(char_arg(args[0], "char-lower-case?").lowercase?) })

      reg.call("char=?", 2, -1, ->(args : Array(SchemeValue)) : SchemeValue { char_chain(args, "char=?", false) { |lhs, rhs| lhs == rhs } })
      reg.call("char<?", 2, -1, ->(args : Array(SchemeValue)) : SchemeValue { char_chain(args, "char<?", false) { |lhs, rhs| lhs < rhs } })
      reg.call("char>?", 2, -1, ->(args : Array(SchemeValue)) : SchemeValue { char_chain(args, "char>?", false) { |lhs, rhs| lhs > rhs } })
      reg.call("char<=?", 2, -1, ->(args : Array(SchemeValue)) : SchemeValue { char_chain(args, "char<=?", false) { |lhs, rhs| lhs <= rhs } })
      reg.call("char>=?", 2, -1, ->(args : Array(SchemeValue)) : SchemeValue { char_chain(args, "char>=?", false) { |lhs, rhs| lhs >= rhs } })

      reg.call("char-ci=?", 2, -1, ->(args : Array(SchemeValue)) : SchemeValue { char_chain(args, "char-ci=?", true) { |lhs, rhs| lhs == rhs } })
      reg.call("char-ci<?", 2, -1, ->(args : Array(SchemeValue)) : SchemeValue { char_chain(args, "char-ci<?", true) { |lhs, rhs| lhs < rhs } })
      reg.call("char-ci>?", 2, -1, ->(args : Array(SchemeValue)) : SchemeValue { char_chain(args, "char-ci>?", true) { |lhs, rhs| lhs > rhs } })
      reg.call("char-ci<=?", 2, -1, ->(args : Array(SchemeValue)) : SchemeValue { char_chain(args, "char-ci<=?", true) { |lhs, rhs| lhs <= rhs } })
      reg.call("char-ci>=?", 2, -1, ->(args : Array(SchemeValue)) : SchemeValue { char_chain(args, "char-ci>=?", true) { |lhs, rhs| lhs >= rhs } })

      # ---- I/O ----
      reg.call("display", 1, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        emit(args[0].display_string, args[1]?, "display")
        NIL.as(SchemeValue)
      end)

      reg.call("write", 1, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        emit(args[0].write_string, args[1]?, "write")
        NIL.as(SchemeValue)
      end)

      # write-simple never emits datum labels for shared/circular structure —
      # since plain write here doesn't emit them either, this is currently a
      # faithful alias.
      reg.call("write-simple", 1, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        emit(args[0].write_string, args[1]?, "write-simple")
        NIL.as(SchemeValue)
      end)

      reg.call("write-shared", 1, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        emit(write_shared_string(args[0]), args[1]?, "write-shared")
        NIL.as(SchemeValue)
      end)

      reg.call("newline", 0, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        emit("\n", args[0]?, "newline")
        NIL.as(SchemeValue)
      end)

      # ---- Ports ----
      # current-*-port are real R7RS parameter objects (not zero-arg
      # builtins) — bound directly so both `(current-output-port)` (apply
      # on a SchemeParameter returns .value, see eval_core) and
      # `(parameterize ((current-output-port p)) ...)` (which needs the
      # identifier itself bound to the parameter, not a procedure that
      # constructs one) work. See Interpreter#initialize for how their
      # default value stays in sync with stdout=/stdin=/stderr=.
      env.define("current-output-port", current_output_port)
      env.define("current-input-port", current_input_port)
      env.define("current-error-port", current_error_port)

      reg.call("flush-output-port", 0, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        p = args[0]? ? port_arg(args[0], "flush-output-port") : current_output_port.value.as(SchemePort)
        raise SchemeRuntimeError.new("flush-output-port: expected an output port") unless p.output?
        p.io.flush
        NIL.as(SchemeValue)
      end)

      # ---- String ports ----
      reg.call("open-input-string", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        s = string_arg(args[0], "open-input-string")
        SchemePort.new(IO::Memory.new(s), true, false).as(SchemeValue)
      end)

      reg.call("open-output-string", 0, 0, ->(_args : Array(SchemeValue)) : SchemeValue do
        SchemePort.new(IO::Memory.new, false, true).as(SchemeValue)
      end)

      reg.call("get-output-string", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        p = port_arg(args[0], "get-output-string")
        io = p.io
        raise SchemeRuntimeError.new("get-output-string: expected a string output port") unless io.is_a?(IO::Memory)
        SchemeStr.new(io.to_s).as(SchemeValue)
      end)

      # Reads and parses exactly one datum from a port, advancing the
      # port's position past it — subsequent `read` calls on the same port
      # continue from where this one left off. Ports don't natively support
      # incremental (partial) Scheme-level reading, so this buffers the
      # port's remaining unread bytes, tokenizes/parses just the first
      # form, then rewrites the port's backing IO::Memory to contain only
      # what's left over after that form — a full re-tokenize per call, but
      # correct and simple, and read is not a hot-path procedure.
      reg.call("read", 0, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        p = input_port_arg(args[0]?, "read")
        read_one_form(p)
      end)

      reg.call("port?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(args[0].is_a?(SchemePort)) })
      reg.call("input-port?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(args[0].is_a?(SchemePort) && args[0].as(SchemePort).input?) })
      reg.call("output-port?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(args[0].is_a?(SchemePort) && args[0].as(SchemePort).output?) })
      reg.call("eof-object?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(args[0].is_a?(SchemeEof)) })
      reg.call("eof-object", 0, 0, ->(_args : Array(SchemeValue)) : SchemeValue { EOF.as(SchemeValue) })

      reg.call("close-port", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        p = port_arg(args[0], "close-port")
        p.io.close unless p.closed?
        p.closed = true
        NIL.as(SchemeValue)
      end)
      reg.call("close-input-port", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        p = port_arg(args[0], "close-input-port")
        p.io.close unless p.closed?
        p.closed = true
        NIL.as(SchemeValue)
      end)
      reg.call("close-output-port", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        p = port_arg(args[0], "close-output-port")
        p.io.close unless p.closed?
        p.closed = true
        NIL.as(SchemeValue)
      end)

      reg.call("read-char", 0, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        p = input_port_arg(args[0]?, "read-char")
        c = p.io.read_char
        c ? SchemeChar.new(c).as(SchemeValue) : EOF.as(SchemeValue)
      end)

      reg.call("peek-char", 0, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        p = input_port_arg(args[0]?, "peek-char")
        c = p.io.peek
        (c.nil? || c.empty?) ? EOF.as(SchemeValue) : SchemeChar.new(c[0].chr).as(SchemeValue)
      end)

      reg.call("read-line", 0, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        p = input_port_arg(args[0]?, "read-line")
        line = p.io.gets(chomp: true)
        line ? SchemeStr.new(line).as(SchemeValue) : EOF.as(SchemeValue)
      end)

      reg.call("read-string", 1, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        n = int_arg(args[0], "read-string")
        raise SchemeRuntimeError.new("read-string: count must be non-negative") if n < 0
        p = input_port_arg(args[1]?, "read-string")
        buf = Bytes.new(n)
        read = p.io.read_fully?(buf)
        read ? SchemeStr.new(String.new(buf)).as(SchemeValue) : EOF.as(SchemeValue)
      end)

      reg.call("write-char", 1, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        c = args[0]
        raise SchemeRuntimeError.new("write-char: expected char, got #{c.write_string}") unless c.is_a?(SchemeChar)
        emit(c.value.to_s, args[1]?, "write-char")
        NIL.as(SchemeValue)
      end)

      reg.call("write-string", 1, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        s = args[0]
        raise SchemeRuntimeError.new("write-string: expected string, got #{s.write_string}") unless s.is_a?(SchemeStr)
        emit(s.value, args[1]?, "write-string")
        NIL.as(SchemeValue)
      end)

      # ---- Promises ----
      reg.call("promise?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue { SchemeBool.of(args[0].is_a?(SchemePromise)) })

      reg.call("make-promise", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        v = args[0]
        if v.is_a?(SchemePromise)
          v.as(SchemeValue)
        else
          p = SchemePromise.new(NIL, @global)
          p.forced = true
          p.value = v
          p.as(SchemeValue)
        end
      end)

      # Forcing a non-promise just returns it unchanged (R7RS: `force`
      # accepts ordinary values for programs written before promises
      # existed). Forcing an already-forced promise returns the memoized
      # value without re-evaluating the thunk.
      # Loops rather than single-stepping so a delay-force chain (where a
      # forced thunk's own result is itself another promise, R7RS's
      # "iterative lazy evaluation" idiom) resolves without growing the
      # Crystal stack one eval() frame per link — each promise in the chain
      # gets forced and its result fed into the next iteration in the same
      # loop, not via recursive force-of-force calls.
      reg.call("force", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        v = args[0]
        while v.is_a?(SchemePromise)
          unless v.forced?
            thunk_expr = v.thunk_expr
            thunk_env = v.thunk_env
            raise SchemeRuntimeError.new("force: promise has no thunk") unless thunk_expr && thunk_env
            result = eval(thunk_expr, thunk_env)
            unless v.forced?
              v.value = result
              v.forced = true
              v.thunk_expr = nil
              v.thunk_env = nil
            end
          end
          v = v.value
        end
        v
      end)

      # ---- Parameters ----
      # The initial value is converted too (R7RS): a parameter's value is
      # always the converter's output, never the raw input, so reads never
      # need to re-apply it.
      reg.call("make-parameter", 1, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        converter = args[1]?
        initial = converter ? apply(converter, [args[0]]) : args[0]
        SchemeParameter.new(initial, converter).as(SchemeValue)
      end)

      # ---- Misc ----
      reg.call("error", 1, -1, ->(args : Array(SchemeValue)) : SchemeValue do
        buf = String::Builder.new
        msg = args[0]
        if msg.is_a?(SchemeStr)
          buf << msg.value
        else
          buf << msg.write_string
        end
        (1...args.size).each do |i|
          buf << ' '
          buf << args[i].write_string
        end
        irritants = args[1..]
        err = SchemeUserError.new(buf.to_s)
        err.payload = SchemeRecord.new(CONDITION_TYPE, [msg, Scheme.a_to_list(irritants)] of SchemeValue)
        raise err
      end)

      # syntax-error is meant for use inside a syntax-rules template (a
      # macro-expansion-time error), but since this interpreter has no
      # separate expansion phase, it behaves the same as `error` when
      # reached during ordinary evaluation.
      reg.call("syntax-error", 1, -1, ->(args : Array(SchemeValue)) : SchemeValue do
        apply(env.get("error"), args)
      end)

      reg.call("features", 0, 0, ->(_args : Array(SchemeValue)) : SchemeValue do
        Scheme.a_to_list(features.map { |feature| SchemeSym.of(feature).as(SchemeValue) })
      end)

      # simplest-rational-in-interval (Stern-Brocot style): the exact
      # rational (or, if either input is inexact, the corresponding
      # inexact value) of least denominator within `epsilon` of `x`.
      reg.call("rationalize", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        x, epsilon = args[0], args[1]
        inexact_result = Scheme.inexact?(x) || Scheme.inexact?(epsilon)
        xf = Scheme.as_f64(x, "rationalize")
        ef = Scheme.as_f64(epsilon, "rationalize").abs
        num, den = simplest_rational_between(xf - ef, xf + ef)
        inexact_result ? SchemeFloat.new(num.to_f64 / den.to_f64).as(SchemeValue) : SchemeRational.make(num, den)
      end)

      # ---- Conditions ----
      reg.call("error-object?", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        v = args[0]
        SchemeBool.of(v.is_a?(SchemeRecord) && v.type.same?(CONDITION_TYPE))
      end)

      reg.call("error-object-message", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        condition_field(args[0], 0, "error-object-message")
      end)

      reg.call("error-object-irritants", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        condition_field(args[0], 1, "error-object-irritants")
      end)

      reg.call("exit", 0, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        code = args.empty? ? 0 : int_arg(args[0], "exit").clamp(0_i64, 255_i64).to_i
        raise SchemeExit.new(code)
      end)

      # ---- Macros ----
      reg.call("gensym", 0, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        prefix = case a = args[0]?
                 when SchemeStr then a.value
                 when SchemeSym then a.name
                 when Nil       then "g"
                 else                raise SchemeRuntimeError.new("gensym: expected a string or symbol prefix")
                 end
        @gensym_counter += 1
        SchemeSym.of("#{prefix}__#{@gensym_counter}")
      end)
    end

    # ---- I/O helpers ----

    # Writes to an explicit port argument when given (as display/write/
    # newline/write-char/write-string's optional trailing port accepts),
    # otherwise falls back to current_output_port's current value — a real
    # R7RS parameter, so `(parameterize ((current-output-port p)) ...)`
    # genuinely redirects this default; stdout= keeps working too, since
    # it resyncs that same parameter's default SchemePort in place.
    private def emit(s : String, port : SchemeValue? = nil, who : String = "write") : Nil
      target = port || current_output_port.value
      raise SchemeRuntimeError.new("#{who}: expected an output port, got #{target.write_string}") unless target.is_a?(SchemePort)
      raise SchemeRuntimeError.new("#{who}: port is closed") if target.closed?
      target.io.print(s)
    end

    # write-shared: like write, but every Cons/SchemeVector reachable by
    # more than one path (shared structure, not just genuine cycles) is
    # represented using #n=/#n# datum labels — the write-side counterpart
    # to the reader's own #n=/#n# support. Two passes: first walk the
    # whole structure counting visits per object (by identity, not
    # value — scheme_equal? would conflate distinct-but-equal structures,
    # which must NOT share a label), stopping re-descent into a node
    # already on the current path so a genuine cycle terminates the count
    # rather than looping forever; then write, assigning each object that
    # was visited more than once a label the first time it's written and
    # a bare #n# reference every time after.
    private def write_shared_string(v : SchemeValue) : String
      visit_counts = Hash(UInt64, Int32).new(0)
      on_path = Set(UInt64).new
      count_shared_visits(v, visit_counts, on_path)

      buf = String::Builder.new
      labels = Hash(UInt64, Int32).new
      next_label = [0] # single-element mutable box, shared across the whole recursive write pass
      write_shared_node(v, buf, visit_counts, labels, next_label)
      buf.to_s
    end

    private def count_shared_visits(v : SchemeValue, counts : Hash(UInt64, Int32), on_path : Set(UInt64)) : Nil
      return unless v.is_a?(Cons) || v.is_a?(SchemeVector)
      id = v.object_id
      seen_before = counts.has_key?(id)
      counts[id] += 1
      # Only descend into children the first time this node is counted —
      # a second/third visit means it'll be written as a bare #n# reference
      # (no re-descent at write time either), and re-walking its children
      # here would double-count grandchildren that are only reachable
      # through this one node, incorrectly flagging them as shared too.
      # on_path additionally guards against a true cycle (a node whose walk
      # is still in progress further up this same call stack).
      return if seen_before || on_path.includes?(id)
      on_path.add(id)
      case v
      when Cons
        count_shared_visits(v.car, counts, on_path)
        count_shared_visits(v.cdr, counts, on_path)
      when SchemeVector
        v.value.each { |elem| count_shared_visits(elem, counts, on_path) }
      end
      on_path.delete(id)
    end

    # ameba:disable Metrics/CyclomaticComplexity
    private def write_shared_node(v : SchemeValue, io : IO, counts : Hash(UInt64, Int32), labels : Hash(UInt64, Int32), next_label : Array(Int32)) : Nil
      unless v.is_a?(Cons) || v.is_a?(SchemeVector)
        v.to_write(io)
        return
      end

      id = v.object_id
      if existing = labels[id]?
        io << '#' << existing << '#'
        return
      end

      shared = counts[id] > 1
      if shared
        label = next_label[0]
        next_label[0] += 1
        labels[id] = label
        io << '#' << label << '='
      end

      case v
      when Cons
        io << '('
        cur : SchemeValue = v
        first = true
        while cur.is_a?(Cons)
          # A shared/cyclic tail (other than the first cell) needs its own
          # dotted #n=/#n# notation — break out of the flat list-printing
          # loop and let recursion handle it via the ". " tail path below,
          # the same way an ordinary improper list's non-nil tail is
          # handled, rather than silently flattening a labelled cdr into
          # this loop as if it were an ordinary list element.
          if !first && (labels.has_key?(cur.object_id) || counts[cur.object_id] > 1)
            io << " . "
            write_shared_node(cur, io, counts, labels, next_label)
            cur = NIL
            break
          end
          io << ' ' unless first
          first = false
          write_shared_node(cur.car, io, counts, labels, next_label)
          cur = cur.cdr
        end
        unless cur.is_a?(SchemeNil)
          io << " . "
          write_shared_node(cur, io, counts, labels, next_label)
        end
        io << ')'
      when SchemeVector
        io << "#("
        v.value.each_with_index do |elem, i|
          io << ' ' if i > 0
          write_shared_node(elem, io, counts, labels, next_label)
        end
        io << ')'
      end
    end

    private def port_arg(v : SchemeValue, who : String) : SchemePort
      raise SchemeRuntimeError.new("#{who}: expected a port, got #{v.write_string}") unless v.is_a?(SchemePort)
      v
    end

    # Reads and parses one datum from `p`, then puts back whatever's left
    # unread so a subsequent `read` on the same port continues where this
    # one stopped. See the `read` builtin's registration comment for why
    # this re-tokenizes the whole remaining buffer rather than reading
    # incrementally.
    private def read_one_form(p : SchemePort) : SchemeValue
      remaining = p.io.gets_to_end
      tokens = Lexer.tokenize(remaining, "<read>")
      reader = Reader.new(tokens)
      return EOF.as(SchemeValue) if reader.at_eof?
      form = reader.read_form
      leftover_tokens = tokens[reader.pos...tokens.size].reject { |token| token.kind == TokKind::EOF }
      leftover_text = leftover_tokens.map { |token| token_source_text(token) }.join(" ")
      new_io = IO::Memory.new(leftover_text)
      p.io = new_io
      form
    rescue ex : SchemeParseError
      # `read`'s own malformed/incomplete input, distinct from a script's
      # own parse errors (which stay plain SchemeParseError/
      # SchemeIncompleteError) — read-error? only recognizes failures that
      # actually went through `read`.
      raise SchemeReadError.new(ex.message)
    end

    # Reconstructs valid re-parseable source text for a token. Most kinds'
    # `.text` already IS source syntax (a symbol, "(", "'", ...), but
    # StrLit/CharLit store the DECODED value (e.g. `.text` is `bar` for the
    # source `"bar"`), so those two need re-quoting/re-escaping rather than
    # being emitted as-is.
    private def token_source_text(token : Token) : String
      case token.kind
      when TokKind::StrLit        then SchemeStr.new(token.text).write_string
      when TokKind::CharLit       then SchemeChar.new(token.text[0]).write_string
      when TokKind::DatumLabelDef then "##{token.text}="
      when TokKind::DatumLabelRef then "##{token.text}#"
      else                             token.text
      end
    end

    private def input_port_arg(v : SchemeValue?, who : String) : SchemePort
      p = v ? port_arg(v, who) : current_input_port.value.as(SchemePort)
      raise SchemeRuntimeError.new("#{who}: expected an input port") unless p.input?
      raise SchemeRuntimeError.new("#{who}: port is closed") if p.closed?
      p
    end

    # ---- Control flow helpers ----

    # Escape-only call/cc: mints a tag unique to this invocation, marks it
    # live for the duration of `f`'s call, and hands `f` a SchemeContinuation
    # carrying that tag. Interpreter#apply's SchemeContinuation arm raises
    # ContinuationInvoked(tag, value) when the continuation is applied; this
    # rescue only catches its OWN tag (a nested call/cc's escape must pass
    # through untouched, hence `raise ex unless ex.tag == tag`), and the
    # `ensure` un-marks the tag as live regardless of how this call ends —
    # success, an ordinary error, or a matching continuation invocation —
    # so a stale (already-returned) continuation is never mistaken for a
    # live one: @cc_tag_counter only increases and tags are never reused.
    private def call_cc(f : SchemeValue) : SchemeValue
      @cc_tag_counter += 1
      tag = @cc_tag_counter
      @live_continuation_tags << tag
      begin
        apply(f, [SchemeContinuation.new(tag).as(SchemeValue)])
      rescue ex : ContinuationInvoked
        raise ex unless ex.tag == tag
        ex.value
      ensure
        @live_continuation_tags.delete(tag)
      end
    end

    # ---- Arithmetic helpers ----

    private def number?(v : SchemeValue) : Bool
      v.is_a?(SchemeInt) || v.is_a?(SchemeRational) || v.is_a?(SchemeFloat) || v.is_a?(SchemeComplex)
    end

    # The simplest (least-denominator) rational within [lo, hi], via the
    # standard Stern-Brocot mediant search. Assumes lo <= hi; if 0 is in
    # range, 0/1 is trivially simplest. Used by `rationalize`.
    private def simplest_rational_between(lo : Float64, hi : Float64) : {Int64, Int64}
      return {0_i64, 1_i64} if lo <= 0 && hi >= 0
      if hi < 0
        num, den = simplest_rational_between(-hi, -lo)
        return {-num, den}
      end

      lo_n, lo_d = 0_i64, 1_i64
      hi_n, hi_d = 1_i64, 0_i64
      loop do
        mid_n = lo_n + hi_n
        mid_d = lo_d + hi_d
        mid = mid_n.to_f64 / mid_d.to_f64
        if mid < lo
          lo_n, lo_d = mid_n, mid_d
        elsif mid > hi
          hi_n, hi_d = mid_n, mid_d
        else
          return {mid_n, mid_d}
        end
      end
    end

    private def checked_int_op(who : String, & : -> Int64) : SchemeValue
      SchemeInt.new(yield)
    rescue OverflowError
      raise SchemeRuntimeError.new("#{who}: integer overflow")
    end

    private def num_add(a : SchemeValue, b : SchemeValue, who : String) : SchemeValue
      return complex_add(to_complex(a, who), to_complex(b, who), who) if a.is_a?(SchemeComplex) || b.is_a?(SchemeComplex)
      Scheme.num_binop3(a, b, who,
        ->(x : Int64, y : Int64) { checked_int_op(who) { x + y } },
        ->(x : {Int64, Int64}, y : {Int64, Int64}) { SchemeRational.make(x[0]*y[1] + y[0]*x[1], x[1]*y[1]) },
        ->(x : Float64, y : Float64) { x + y })
    end

    private def num_sub(a : SchemeValue, b : SchemeValue, who : String) : SchemeValue
      return complex_sub(to_complex(a, who), to_complex(b, who), who) if a.is_a?(SchemeComplex) || b.is_a?(SchemeComplex)
      Scheme.num_binop3(a, b, who,
        ->(x : Int64, y : Int64) { checked_int_op(who) { x - y } },
        ->(x : {Int64, Int64}, y : {Int64, Int64}) { SchemeRational.make(x[0]*y[1] - y[0]*x[1], x[1]*y[1]) },
        ->(x : Float64, y : Float64) { x - y })
    end

    private def num_mul(a : SchemeValue, b : SchemeValue, who : String) : SchemeValue
      return complex_mul(to_complex(a, who), to_complex(b, who), who) if a.is_a?(SchemeComplex) || b.is_a?(SchemeComplex)
      Scheme.num_binop3(a, b, who,
        ->(x : Int64, y : Int64) { checked_int_op(who) { x * y } },
        ->(x : {Int64, Int64}, y : {Int64, Int64}) { SchemeRational.make(x[0]*y[0], x[1]*y[1]) },
        ->(x : Float64, y : Float64) { x * y })
    end

    # base ** exp for exp >= 0, raising on Int64 overflow. Shared by expt's
    # positive-exponent path and its negative-exponent path (which negates
    # the exponent, computes the positive power, then routes the result
    # through SchemeRational.make as a reciprocal).
    private def expt_int_pow(base : Int64, exp : Int64) : Int64
      result = 1_i64
      begin
        exp.times { result *= base }
      rescue OverflowError
        raise SchemeRuntimeError.new("expt: integer overflow")
      end
      result
    end

    # Integer square root of a non-negative Int64: {floor(sqrt(n)), n -
    # floor(sqrt(n))**2}. A zero remainder means n is a perfect square.
    # Shared by sqrt's exact fast path and the exact-integer-sqrt builtin.
    private def exact_integer_sqrt_pair(n : Int64) : {Int64, Int64}
      return {0_i64, 0_i64} if n == 0
      root = Math.sqrt(n.to_f64).to_i64
      # Float64 sqrt can be off by one at the boundary; correct it.
      while (root + 1) * (root + 1) <= n
        root += 1
      end
      while root * root > n
        root -= 1
      end
      {root, n - root * root}
    end

    # inexact->exact / exact on a SchemeInt/SchemeRational is the identity
    # (already exact); on a SchemeFloat, decomposes the IEEE-754 double
    # into an exact numerator/denominator via Crystal's BigRational (which
    # already handles the exponent/subnormal decomposition correctly, so
    # this doesn't hand-roll bit manipulation), then downcasts to Int64 —
    # raising a clear error rather than silently losing precision for a
    # float whose exact value doesn't fit (e.g. 1e300).
    private def to_exact(v : SchemeValue) : SchemeValue
      return v if v.is_a?(SchemeInt) || v.is_a?(SchemeRational)
      raise SchemeRuntimeError.new("exact: expected number, got #{v.write_string}") unless v.is_a?(SchemeFloat)
      raise SchemeRuntimeError.new("exact: cannot convert a non-finite float") unless v.value.finite?
      r = BigRational.new(v.value)
      begin
        SchemeRational.make(r.numerator.to_i64, r.denominator.to_i64)
      rescue OverflowError
        raise SchemeRuntimeError.new("exact: magnitude too large to represent exactly")
      end
    end

    private def round_like(v : SchemeValue, who : String, rational_op : Int64, Int64 -> Int64, &block : Float64 -> Float64) : SchemeValue
      case v
      when SchemeInt      then v
      when SchemeRational then SchemeInt.new(rational_op.call(v.numerator, v.denominator))
      when SchemeFloat    then SchemeFloat.new(block.call(v.value))
      else                     raise SchemeRuntimeError.new("#{who}: expected number, got #{v.write_string}")
      end
    end

    # Exact floor/ceiling/truncate/round on a reduced rational n/d (d > 0,
    # per SchemeRational.make's own invariant) — staying exact throughout,
    # since going through Float64 could lose precision or overflow for
    # large numerators/denominators. Crystal's // is floor division, so
    # floor is a one-liner; the other three build on it.
    private def rational_floor(n : Int64, d : Int64) : Int64
      n // d
    end

    private def rational_ceiling(n : Int64, d : Int64) : Int64
      -((-n) // d)
    end

    private def rational_truncate(n : Int64, d : Int64) : Int64
      n.sign < 0 ? rational_ceiling(n, d) : rational_floor(n, d)
    end

    # Round-half-to-even: compare the fractional part against 1/2 by
    # cross-multiplication (2 * remainder vs d) to stay in exact integer
    # arithmetic, then break an exact tie by rounding to the even quotient.
    private def rational_round(n : Int64, d : Int64) : Int64
      q = rational_floor(n, d)
      r = n - q * d
      twice_r = r * 2
      if twice_r < d
        q
      elsif twice_r > d
        q + 1
      else
        q.even? ? q : q + 1
      end
    end

    # Exact/exact division produces an exact SchemeRational (auto-collapsing
    # to SchemeInt when it divides evenly) instead of falling back to an
    # inexact float — e.g. (/ 1 3) now yields exact 1/3, not 0.333...
    # Division by exact zero is still an error; division by inexact
    # (float) zero also still raises for now (kept as today's behavior,
    # not revisited by this change).
    private def divide(a : SchemeValue, b : SchemeValue) : SchemeValue
      return complex_div(to_complex(a, "/"), to_complex(b, "/")) if a.is_a?(SchemeComplex) || b.is_a?(SchemeComplex)
      rank = Math.max(Scheme.num_rank(a, "/"), Scheme.num_rank(b, "/"))
      if rank <= 1
        an, ad = Scheme.as_ratio(a)
        bn, bd = Scheme.as_ratio(b)
        raise SchemeRuntimeError.new("/: division by zero") if bn == 0
        begin
          SchemeRational.make(an * bd, ad * bn)
        rescue OverflowError
          raise SchemeRuntimeError.new("/: integer overflow")
        end
      else
        bf = Scheme.as_f64(b, "/")
        raise SchemeRuntimeError.new("/: division by zero") if bf == 0.0
        SchemeFloat.new(Scheme.as_f64(a, "/") / bf)
      end
    end

    private def string_chain_cmp(args : Array(SchemeValue), who : String, &block : String, String -> Bool) : SchemeValue
      strs = args.map do |arg|
        raise SchemeRuntimeError.new("#{who}: expected string, got #{arg.write_string}") unless arg.is_a?(SchemeStr)
        arg.value
      end
      ok = (0...strs.size - 1).all? { |i| block.call(strs[i], strs[i + 1]) }
      SchemeBool.of(ok)
    end

    private def int_arg(v : SchemeValue, who : String) : Int64
      case v
      when SchemeInt then v.value
      else
        raise SchemeRuntimeError.new("#{who}: expected integer, got #{v.write_string}")
      end
    end

    private def radix_arg(v : SchemeValue?, who : String) : Int32
      return 10 unless v
      r = int_arg(v, who)
      raise SchemeRuntimeError.new("#{who}: radix must be 2, 8, 10, or 16") unless {2_i64, 8_i64, 10_i64, 16_i64}.includes?(r)
      r.to_i32
    end

    private def environment_specifier_arg(v : SchemeValue, who : String) : Env
      case v
      when SchemeEnvironment then v.env
      else                        raise SchemeRuntimeError.new("#{who}: expected an environment specifier, got #{v.write_string}")
      end
    end

    private def parse_number_string(txt : String, radix : Int32) : SchemeValue
      if radix != 10
        begin
          return SchemeInt.new(txt.to_i64(radix)).as(SchemeValue)
        rescue ArgumentError
          return FALSE.as(SchemeValue)
        end
      end
      if Lexer::INT_RE.matches?(txt) && (parsed_int = txt.to_i64?)
        return SchemeInt.new(parsed_int).as(SchemeValue)
      end
      is_float_syntax = txt.includes?('.') || txt.includes?('e') || txt.includes?('E')
      if Lexer::FLOAT_RE.matches?(txt) && is_float_syntax && (parsed_float = txt.to_f64?)
        return SchemeFloat.new(parsed_float).as(SchemeValue)
      end
      FALSE.as(SchemeValue)
    end

    # Shared by assq/assv (use_eqv: true, no comparator) and assoc (use_eqv:
    # false, equal? by default, or a caller-supplied 2-arg predicate).
    private def assoc_impl(key : SchemeValue, alist : SchemeValue, comparator : SchemeValue?, use_eqv : Bool) : SchemeValue
      matches = ->(candidate : SchemeValue) : Bool do
        if comparator
          Scheme.truthy?(apply(comparator, [key, candidate]))
        elsif use_eqv
          Scheme.scheme_eqv?(key, candidate)
        else
          Scheme.scheme_equal?(key, candidate)
        end
      end
      cur = alist
      while cur.is_a?(Cons)
        entry = cur.car
        if entry.is_a?(Cons) && matches.call(entry.car)
          return entry
        end
        cur = cur.cdr
      end
      FALSE.as(SchemeValue)
    end

    private def member_impl(x : SchemeValue, lst : SchemeValue, comparator : SchemeValue?, use_eqv : Bool) : SchemeValue
      matches = ->(candidate : SchemeValue) : Bool do
        if comparator
          Scheme.truthy?(apply(comparator, [x, candidate]))
        elsif use_eqv
          Scheme.scheme_eqv?(x, candidate)
        else
          Scheme.scheme_equal?(x, candidate)
        end
      end
      cur = lst
      while cur.is_a?(Cons)
        return cur if matches.call(cur.car)
        cur = cur.cdr
      end
      FALSE.as(SchemeValue)
    end

    private def string_arg(v : SchemeValue, who : String) : String
      raise SchemeRuntimeError.new("#{who}: expected string, got #{v.write_string}") unless v.is_a?(SchemeStr)
      v.value
    end

    # Resolves optional start/end args (R7RS convention: start defaults to
    # 0, end defaults to the sequence's length) into a validated {first,
    # last} pair, shared by every string/vector procedure that accepts an
    # optional range.
    private def seq_range_args(size : Int32, start_arg : SchemeValue?, end_arg : SchemeValue?, who : String) : {Int32, Int32}
      first = start_arg ? int_arg(start_arg, who).to_i32 : 0
      last = end_arg ? int_arg(end_arg, who).to_i32 : size
      raise SchemeRuntimeError.new("#{who}: range out of bounds") if first < 0 || last > size || first > last
      {first, last}
    end

    private def char_arg(v : SchemeValue, who : String) : Char
      raise SchemeRuntimeError.new("#{who}: expected char, got #{v.write_string}") unless v.is_a?(SchemeChar)
      v.value
    end

    private def char_chain(args : Array(SchemeValue), who : String, case_insensitive : Bool, &cmp : Char, Char -> Bool) : SchemeValue
      (0...args.size - 1).each do |i|
        a = char_arg(args[i], who)
        b = char_arg(args[i + 1], who)
        a, b = a.downcase, b.downcase if case_insensitive
        return FALSE.as(SchemeValue) unless cmp.call(a, b)
      end
      TRUE.as(SchemeValue)
    end

    private def vector_arg(v : SchemeValue, who : String) : Array(SchemeValue)
      raise SchemeRuntimeError.new("#{who}: expected vector, got #{v.write_string}") unless v.is_a?(SchemeVector)
      v.value
    end

    private def vector_index_arg(v : SchemeValue, who : String) : Int32
      raise SchemeRuntimeError.new("#{who}: expected integer, got #{v.write_string}") unless v.is_a?(SchemeInt)
      v.value.to_i32
    end

    private def blob_arg(v : SchemeValue, who : String) : Bytes
      raise SchemeRuntimeError.new("#{who}: expected blob, got #{v.write_string}") unless v.is_a?(SchemeBlob)
      v.value
    end

    private def condition_field(v : SchemeValue, idx : Int32, who : String) : SchemeValue
      raise SchemeRuntimeError.new("#{who}: expected an error object, got #{v.write_string}") unless v.is_a?(SchemeRecord) && v.type.same?(CONDITION_TYPE)
      v.fields[idx]
    end

    private def fold_minmax(args : Array(SchemeValue), who : String, is_min : Bool) : SchemeValue
      best = args[0]
      unless best.is_a?(SchemeInt) || best.is_a?(SchemeFloat)
        raise SchemeRuntimeError.new("#{who}: expected number, got #{best.write_string}")
      end
      any_float = best.is_a?(SchemeFloat)
      (1...args.size).each do |i|
        v = args[i]
        unless v.is_a?(SchemeInt) || v.is_a?(SchemeFloat)
          raise SchemeRuntimeError.new("#{who}: expected number, got #{v.write_string}")
        end
        any_float = true if v.is_a?(SchemeFloat)
        bv = Scheme.as_f64(best, who)
        vv = Scheme.as_f64(v, who)
        if is_min
          best = v if vv < bv
        else
          best = v if vv > bv
        end
      end
      if any_float && best.is_a?(SchemeInt)
        SchemeFloat.new(best.value.to_f64)
      else
        best
      end
    end

    # Three-way exact comparison (-1, 0, 1) between two exact numbers (int
    # or rational), via cross-multiplication in BigInt so large numerator/
    # denominator pairs can't silently overflow Int64 mid-comparison — this
    # widening is purely internal, a BigInt never becomes a Scheme-visible
    # value.
    private def exact_compare(a : SchemeValue, b : SchemeValue) : Int32
      an, ad = Scheme.as_ratio(a)
      bn, bd = Scheme.as_ratio(b)
      lhs = an.to_big_i * bd
      rhs = bn.to_big_i * ad
      return -1 if lhs < rhs
      return 1 if lhs > rhs
      0
    end

    # Compares args pairwise left-to-right. Two exact operands (int or
    # rational) compare exactly via cross-multiplication, with no float
    # round-trip; float contagion (any inexact operand) falls back to
    # ordinary Float64 comparison, same as before. A nil <=> (e.g. one side
    # is NaN) is treated as "not equal, not less, not greater" — every
    # cmp.call arm below is false for such a result, matching R7RS's
    # treatment of NaN in numeric comparisons.
    private def num_chain(args : Array(SchemeValue), who : String, &cmp : Int32 -> Bool) : SchemeValue
      (0...args.size - 1).each do |i|
        a, b = args[i], args[i + 1]
        cmp_result =
          if Scheme.exact?(a) && Scheme.exact?(b)
            exact_compare(a, b)
          else
            Scheme.as_f64(a, who) <=> Scheme.as_f64(b, who)
          end
        return FALSE.as(SchemeValue) if cmp_result.nil? || !cmp.call(cmp_result)
      end
      TRUE.as(SchemeValue)
    end
  end
end
