# ===========================================================================
# Builtins
# ===========================================================================

module LISP
  class Interpreter
    private def install_builtins(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(LispValue) -> LispValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      # ---- Arithmetic ----
      reg.call("+", 0, -1, ->(args : Array(LispValue)) : LispValue do
        acc : LispValue = LispInt.new(0_i64)
        args.each { |a| acc = num_add(acc, a, "+") }
        acc
      end)

      reg.call("*", 0, -1, ->(args : Array(LispValue)) : LispValue do
        acc : LispValue = LispInt.new(1_i64)
        args.each { |a| acc = num_mul(acc, a, "*") }
        acc
      end)

      reg.call("-", 1, -1, ->(args : Array(LispValue)) : LispValue do
        if args.size == 1
          num_sub(LispInt.new(0_i64), args[0], "-")
        else
          acc = args[0]
          (1...args.size).each { |i| acc = num_sub(acc, args[i], "-") }
          acc
        end
      end)

      reg.call("/", 1, -1, ->(args : Array(LispValue)) : LispValue do
        if args.size == 1
          divide(LispInt.new(1_i64), args[0])
        else
          acc = args[0]
          (1...args.size).each { |i| acc = divide(acc, args[i]) }
          acc
        end
      end)

      reg.call("modulo", 2, 2, ->(args : Array(LispValue)) : LispValue do
        a = int_arg(args[0], "modulo")
        b = int_arg(args[1], "modulo")
        raise LispRuntimeError.new("modulo: division by zero") if b == 0
        begin
          LispInt.new(a % b)
        rescue ArgumentError | OverflowError
          raise LispRuntimeError.new("modulo: integer overflow")
        end
      end)

      reg.call("remainder", 2, 2, ->(args : Array(LispValue)) : LispValue do
        a = int_arg(args[0], "remainder")
        b = int_arg(args[1], "remainder")
        raise LispRuntimeError.new("remainder: division by zero") if b == 0
        LispInt.new(a.remainder(b))
      end)

      reg.call("quotient", 2, 2, ->(args : Array(LispValue)) : LispValue do
        a = int_arg(args[0], "quotient")
        b = int_arg(args[1], "quotient")
        raise LispRuntimeError.new("quotient: division by zero") if b == 0
        begin
          LispInt.new(a.tdiv(b)) # truncate toward zero
        rescue ArgumentError | OverflowError
          raise LispRuntimeError.new("quotient: integer overflow")
        end
      end)

      reg.call("abs", 1, 1, ->(args : Array(LispValue)) : LispValue do
        v = args[0]
        case v
        when LispInt
          begin
            LispInt.new(v.value.abs)
          rescue OverflowError
            raise LispRuntimeError.new("abs: integer overflow")
          end
        when LispFloat then LispFloat.new(v.value.abs)
        else                raise LispRuntimeError.new("abs: expected number, got #{v.write_string}")
        end
      end)

      reg.call("min", 1, -1, ->(args : Array(LispValue)) : LispValue do
        fold_minmax(args, "min", true)
      end)

      reg.call("max", 1, -1, ->(args : Array(LispValue)) : LispValue do
        fold_minmax(args, "max", false)
      end)

      reg.call("expt", 2, 2, ->(args : Array(LispValue)) : LispValue do
        base = args[0]
        ex = args[1]
        if base.is_a?(LispInt) && ex.is_a?(LispInt) && ex.value >= 0
          result = 1_i64
          b = base.value
          e = ex.value
          begin
            e.times { result *= b }
          rescue OverflowError
            raise LispRuntimeError.new("expt: integer overflow")
          end
          LispInt.new(result)
        else
          LispFloat.new(LISP.as_f64(base, "expt") ** LISP.as_f64(ex, "expt"))
        end
      end)

      reg.call("sqrt", 1, 1, ->(args : Array(LispValue)) : LispValue do
        LispFloat.new(Math.sqrt(LISP.as_f64(args[0], "sqrt")))
      end)

      # ---- Comparisons ----
      reg.call("=", 1, -1, ->(args : Array(LispValue)) : LispValue { num_chain(args, "=") { |a, b| a == b } })
      reg.call("<", 1, -1, ->(args : Array(LispValue)) : LispValue { num_chain(args, "<") { |a, b| a < b } })
      reg.call(">", 1, -1, ->(args : Array(LispValue)) : LispValue { num_chain(args, ">") { |a, b| a > b } })
      reg.call("<=", 1, -1, ->(args : Array(LispValue)) : LispValue { num_chain(args, "<=") { |a, b| a <= b } })
      reg.call(">=", 1, -1, ->(args : Array(LispValue)) : LispValue { num_chain(args, ">=") { |a, b| a >= b } })

      reg.call("not", 1, 1, ->(args : Array(LispValue)) : LispValue { LispBool.of(!LISP.truthy?(args[0])) })

      reg.call("eq?", 2, 2, ->(args : Array(LispValue)) : LispValue { LispBool.of(LISP.lisp_eqv?(args[0], args[1])) })
      reg.call("eqv?", 2, 2, ->(args : Array(LispValue)) : LispValue { LispBool.of(LISP.lisp_eqv?(args[0], args[1])) })
      reg.call("equal?", 2, 2, ->(args : Array(LispValue)) : LispValue { LispBool.of(LISP.lisp_equal?(args[0], args[1])) })

      # ---- Pairs & lists ----
      reg.call("cons", 2, 2, ->(args : Array(LispValue)) : LispValue { Cons.new(args[0], args[1]).as(LispValue) })

      reg.call("car", 1, 1, ->(args : Array(LispValue)) : LispValue do
        v = args[0]
        raise LispRuntimeError.new("car: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
        v.car
      end)

      reg.call("cdr", 1, 1, ->(args : Array(LispValue)) : LispValue do
        v = args[0]
        raise LispRuntimeError.new("cdr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
        v.cdr
      end)

      reg.call("set-car!", 2, 2, ->(args : Array(LispValue)) : LispValue do
        v = args[0]
        raise LispRuntimeError.new("set-car!: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
        v.car = args[1]
        NIL.as(LispValue)
      end)

      reg.call("set-cdr!", 2, 2, ->(args : Array(LispValue)) : LispValue do
        v = args[0]
        raise LispRuntimeError.new("set-cdr!: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
        v.cdr = args[1]
        NIL.as(LispValue)
      end)

      reg.call("list", 0, -1, ->(args : Array(LispValue)) : LispValue { LISP.a_to_list(args) })

      reg.call("append", 0, -1, ->(args : Array(LispValue)) : LispValue do
        return NIL.as(LispValue) if args.empty?
        result = args[args.size - 1]
        i = args.size - 2
        while i >= 0
          elems = LISP.list_to_a(args[i])
          result = LISP.a_to_list(elems, result)
          i -= 1
        end
        result
      end)

      reg.call("length", 1, 1, ->(args : Array(LispValue)) : LispValue do
        LispInt.new(LISP.list_to_a(args[0]).size.to_i64)
      end)

      reg.call("reverse", 1, 1, ->(args : Array(LispValue)) : LispValue do
        elems = LISP.list_to_a(args[0])
        LISP.a_to_list(elems.reverse)
      end)

      reg.call("list-ref", 2, 2, ->(args : Array(LispValue)) : LispValue do
        elems = LISP.list_to_a(args[0])
        idx = int_arg(args[1], "list-ref")
        if idx < 0 || idx >= elems.size
          raise LispRuntimeError.new("list-ref: index #{idx} out of range")
        end
        elems[idx]
      end)

      reg.call("null?", 1, 1, ->(args : Array(LispValue)) : LispValue { LispBool.of(args[0].is_a?(LispNil)) })
      reg.call("pair?", 1, 1, ->(args : Array(LispValue)) : LispValue { LispBool.of(args[0].is_a?(Cons)) })
      reg.call("list?", 1, 1, ->(args : Array(LispValue)) : LispValue { LispBool.of(LISP.proper_list?(args[0])) })

      # ---- Vectors ----
      reg.call("vector", 0, -1, ->(args : Array(LispValue)) : LispValue { LispVector.new(args.dup) })

      reg.call("make-vector", 1, 2, ->(args : Array(LispValue)) : LispValue do
        n = vector_index_arg(args[0], "make-vector")
        raise LispRuntimeError.new("make-vector: size must be non-negative") if n < 0
        fill = args.size == 2 ? args[1] : NIL.as(LispValue)
        LispVector.new(Array.new(n) { fill })
      end)

      reg.call("vector-ref", 2, 2, ->(args : Array(LispValue)) : LispValue do
        v = vector_arg(args[0], "vector-ref")
        i = vector_index_arg(args[1], "vector-ref")
        raise LispRuntimeError.new("vector-ref: index #{i} out of range") if i < 0 || i >= v.size
        v[i]
      end)

      reg.call("vector-set!", 3, 3, ->(args : Array(LispValue)) : LispValue do
        v = vector_arg(args[0], "vector-set!")
        i = vector_index_arg(args[1], "vector-set!")
        raise LispRuntimeError.new("vector-set!: index #{i} out of range") if i < 0 || i >= v.size
        v[i] = args[2]
        NIL.as(LispValue)
      end)

      reg.call("vector-length", 1, 1, ->(args : Array(LispValue)) : LispValue do
        LispInt.new(vector_arg(args[0], "vector-length").size.to_i64)
      end)

      reg.call("vector?", 1, 1, ->(args : Array(LispValue)) : LispValue { LispBool.of(args[0].is_a?(LispVector)) })

      reg.call("vector->list", 1, 1, ->(args : Array(LispValue)) : LispValue do
        LISP.a_to_list(vector_arg(args[0], "vector->list").dup)
      end)

      reg.call("list->vector", 1, 1, ->(args : Array(LispValue)) : LispValue do
        LispVector.new(LISP.list_to_a(args[0]))
      end)

      # ---- Blobs ----
      reg.call("blob?", 1, 1, ->(args : Array(LispValue)) : LispValue { LispBool.of(args[0].is_a?(LispBlob)) })

      reg.call("blob-size", 1, 1, ->(args : Array(LispValue)) : LispValue do
        LispInt.new(blob_arg(args[0], "blob-size").size.to_i64)
      end)

      reg.call("blob->string", 1, 1, ->(args : Array(LispValue)) : LispValue do
        bytes = blob_arg(args[0], "blob->string")
        s = String.new(bytes)
        raise LispRuntimeError.new("blob->string: invalid UTF-8 byte sequence") unless s.valid_encoding?
        LispStr.new(s)
      end)

      reg.call("string->blob", 1, 1, ->(args : Array(LispValue)) : LispValue do
        s = args[0]
        raise LispRuntimeError.new("string->blob: expected string, got #{s.write_string}") unless s.is_a?(LispStr)
        LispBlob.new(s.value.to_slice)
      end)

      # ---- Higher-order ----
      reg.call("map", 2, -1, ->(args : Array(LispValue)) : LispValue do
        f = args[0]
        lists = args[1..-1].map { |l| LISP.list_to_a(l) }
        minlen = lists.map(&.size).min
        acc = [] of LispValue
        (0...minlen).each do |i|
          call_args = lists.map { |l| l[i] }
          acc << apply(f, call_args)
        end
        LISP.a_to_list(acc)
      end)

      reg.call("filter", 2, 2, ->(args : Array(LispValue)) : LispValue do
        f = args[0]
        elems = LISP.list_to_a(args[1])
        acc = [] of LispValue
        elems.each { |x| acc << x if LISP.truthy?(apply(f, [x])) }
        LISP.a_to_list(acc)
      end)

      reg.call("reduce", 3, 3, ->(args : Array(LispValue)) : LispValue do
        f = args[0]
        acc = args[1]
        elems = LISP.list_to_a(args[2])
        elems.each { |x| acc = apply(f, [acc, x]) }
        acc
      end)

      reg.call("foldl", 3, 3, ->(args : Array(LispValue)) : LispValue do
        f = args[0]
        acc = args[1]
        elems = LISP.list_to_a(args[2])
        elems.each { |x| acc = apply(f, [acc, x]) }
        acc
      end)

      reg.call("foldr", 3, 3, ->(args : Array(LispValue)) : LispValue do
        f = args[0]
        acc = args[1]
        elems = LISP.list_to_a(args[2])
        i = elems.size - 1
        while i >= 0
          acc = apply(f, [elems[i], acc])
          i -= 1
        end
        acc
      end)

      reg.call("for-each", 2, -1, ->(args : Array(LispValue)) : LispValue do
        f = args[0]
        lists = args[1..-1].map { |l| LISP.list_to_a(l) }
        minlen = lists.map(&.size).min
        (0...minlen).each do |i|
          call_args = lists.map { |l| l[i] }
          apply(f, call_args)
        end
        NIL.as(LispValue)
      end)

      reg.call("apply", 2, -1, ->(args : Array(LispValue)) : LispValue do
        f = args[0]
        middle = args[1...args.size - 1]
        last = args[args.size - 1]
        call_args = middle + LISP.list_to_a(last)
        apply(f, call_args)
      end)

      # ---- Type predicates ----
      reg.call("number?", 1, 1, ->(args : Array(LispValue)) : LispValue { LispBool.of(args[0].is_a?(LispInt) || args[0].is_a?(LispFloat)) })
      reg.call("integer?", 1, 1, ->(args : Array(LispValue)) : LispValue { LispBool.of(args[0].is_a?(LispInt)) })
      reg.call("float?", 1, 1, ->(args : Array(LispValue)) : LispValue { LispBool.of(args[0].is_a?(LispFloat)) })
      reg.call("real?", 1, 1, ->(args : Array(LispValue)) : LispValue { LispBool.of(args[0].is_a?(LispInt) || args[0].is_a?(LispFloat)) })
      reg.call("symbol?", 1, 1, ->(args : Array(LispValue)) : LispValue { LispBool.of(args[0].is_a?(LispSym)) })
      reg.call("string?", 1, 1, ->(args : Array(LispValue)) : LispValue { LispBool.of(args[0].is_a?(LispStr)) })
      reg.call("boolean?", 1, 1, ->(args : Array(LispValue)) : LispValue { LispBool.of(args[0].is_a?(LispBool)) })
      reg.call("char?", 1, 1, ->(args : Array(LispValue)) : LispValue { LispBool.of(args[0].is_a?(LispChar)) })
      reg.call("procedure?", 1, 1, ->(args : Array(LispValue)) : LispValue { LispBool.of(args[0].is_a?(Builtin) || args[0].is_a?(Lambda)) })
      reg.call("macro?", 1, 1, ->(args : Array(LispValue)) : LispValue { LispBool.of(args[0].is_a?(Macro)) })

      # ---- Strings & conversion ----
      reg.call("string-append", 0, -1, ->(args : Array(LispValue)) : LispValue do
        buf = String::Builder.new
        args.each do |a|
          raise LispRuntimeError.new("string-append: expected string, got #{a.write_string}") unless a.is_a?(LispStr)
          buf << a.value
        end
        LispStr.new(buf.to_s)
      end)

      reg.call("string-length", 1, 1, ->(args : Array(LispValue)) : LispValue do
        s = args[0]
        raise LispRuntimeError.new("string-length: expected string, got #{s.write_string}") unless s.is_a?(LispStr)
        LispInt.new(s.value.size.to_i64)
      end)

      reg.call("substring", 2, 3, ->(args : Array(LispValue)) : LispValue do
        s = args[0]
        raise LispRuntimeError.new("substring: expected string, got #{s.write_string}") unless s.is_a?(LispStr)
        len = s.value.size.to_i64
        start64 = int_arg(args[1], "substring")
        endi64 = args.size == 3 ? int_arg(args[2], "substring") : len
        if start64 < 0 || endi64 > len || start64 > endi64
          raise LispRuntimeError.new("substring: index out of range")
        end
        LispStr.new(s.value[start64.to_i...endi64.to_i])
      end)

      reg.call("string->symbol", 1, 1, ->(args : Array(LispValue)) : LispValue do
        s = args[0]
        raise LispRuntimeError.new("string->symbol: expected string, got #{s.write_string}") unless s.is_a?(LispStr)
        LispSym.of(s.value)
      end)

      reg.call("symbol->string", 1, 1, ->(args : Array(LispValue)) : LispValue do
        s = args[0]
        raise LispRuntimeError.new("symbol->string: expected symbol, got #{s.write_string}") unless s.is_a?(LispSym)
        LispStr.new(s.name)
      end)

      reg.call("number->string", 1, 1, ->(args : Array(LispValue)) : LispValue do
        n = args[0]
        unless n.is_a?(LispInt) || n.is_a?(LispFloat)
          raise LispRuntimeError.new("number->string: expected number, got #{n.write_string}")
        end
        LispStr.new(n.display_string)
      end)

      reg.call("string->number", 1, 1, ->(args : Array(LispValue)) : LispValue do
        s = args[0]
        raise LispRuntimeError.new("string->number: expected string, got #{s.write_string}") unless s.is_a?(LispStr)
        txt = s.value
        if Lexer::INT_RE.matches?(txt)
          begin
            return LispInt.new(txt.to_i64).as(LispValue)
          rescue ArgumentError
          end
        end
        if Lexer::FLOAT_RE.matches?(txt) && (txt.includes?('.') || txt.includes?('e') || txt.includes?('E'))
          begin
            return LispFloat.new(txt.to_f64).as(LispValue)
          rescue ArgumentError
          end
        end
        FALSE.as(LispValue)
      end)

      reg.call("string=?", 2, -1, ->(args : Array(LispValue)) : LispValue do
        first = args[0]
        raise LispRuntimeError.new("string=?: expected string, got #{first.write_string}") unless first.is_a?(LispStr)
        (1...args.size).each do |i|
          s = args[i]
          raise LispRuntimeError.new("string=?: expected string, got #{s.write_string}") unless s.is_a?(LispStr)
          return FALSE.as(LispValue) unless s.value == first.value
        end
        TRUE.as(LispValue)
      end)

      reg.call("string<?", 2, -1, ->(args : Array(LispValue)) : LispValue { string_chain_cmp(args, "string<?") { |lhs, rhs| lhs < rhs } })
      reg.call("string>?", 2, -1, ->(args : Array(LispValue)) : LispValue { string_chain_cmp(args, "string>?") { |lhs, rhs| lhs > rhs } })
      reg.call("string<=?", 2, -1, ->(args : Array(LispValue)) : LispValue { string_chain_cmp(args, "string<=?") { |lhs, rhs| lhs <= rhs } })
      reg.call("string>=?", 2, -1, ->(args : Array(LispValue)) : LispValue { string_chain_cmp(args, "string>=?") { |lhs, rhs| lhs >= rhs } })

      reg.call("string-ref", 2, 2, ->(args : Array(LispValue)) : LispValue do
        s = args[0]
        raise LispRuntimeError.new("string-ref: expected string, got #{s.write_string}") unless s.is_a?(LispStr)
        idx = int_arg(args[1], "string-ref")
        raise LispRuntimeError.new("string-ref: index out of range") if idx < 0 || idx >= s.value.size
        LispChar.new(s.value[idx.to_i])
      end)

      reg.call("string->list", 1, 1, ->(args : Array(LispValue)) : LispValue do
        s = args[0]
        raise LispRuntimeError.new("string->list: expected string, got #{s.write_string}") unless s.is_a?(LispStr)
        LISP.a_to_list(s.value.chars.map { |chr| LispChar.new(chr).as(LispValue) })
      end)

      reg.call("list->string", 1, 1, ->(args : Array(LispValue)) : LispValue do
        buf = String::Builder.new
        LISP.list_to_a(args[0]).each do |v|
          raise LispRuntimeError.new("list->string: expected list of chars, got #{v.write_string}") unless v.is_a?(LispChar)
          buf << v.value
        end
        LispStr.new(buf.to_s)
      end)

      reg.call("make-string", 1, 2, ->(args : Array(LispValue)) : LispValue do
        len = int_arg(args[0], "make-string")
        raise LispRuntimeError.new("make-string: length must be non-negative") if len < 0
        fill = ' '
        if args.size == 2
          f = args[1]
          raise LispRuntimeError.new("make-string: expected char, got #{f.write_string}") unless f.is_a?(LispChar)
          fill = f.value
        end
        LispStr.new(fill.to_s * len)
      end)

      reg.call("char->integer", 1, 1, ->(args : Array(LispValue)) : LispValue do
        c = args[0]
        raise LispRuntimeError.new("char->integer: expected char, got #{c.write_string}") unless c.is_a?(LispChar)
        LispInt.new(c.value.ord.to_i64)
      end)

      reg.call("integer->char", 1, 1, ->(args : Array(LispValue)) : LispValue do
        n = int_arg(args[0], "integer->char")
        raise LispRuntimeError.new("integer->char: code point out of range") if n < 0 || n > 0x10FFFF
        LispChar.new(n.to_i32.chr)
      end)

      # ---- I/O ----
      reg.call("display", 1, 1, ->(args : Array(LispValue)) : LispValue do
        emit(args[0].display_string)
        NIL.as(LispValue)
      end)

      reg.call("write", 1, 1, ->(args : Array(LispValue)) : LispValue do
        emit(args[0].write_string)
        NIL.as(LispValue)
      end)

      reg.call("newline", 0, 0, ->(args : Array(LispValue)) : LispValue do
        emit("\n")
        NIL.as(LispValue)
      end)

      reg.call("print", 0, -1, ->(args : Array(LispValue)) : LispValue do
        args.each { |a| emit(a.display_string) }
        NIL.as(LispValue)
      end)

      reg.call("println", 0, -1, ->(args : Array(LispValue)) : LispValue do
        args.each { |a| emit(a.display_string) }
        emit("\n")
        NIL.as(LispValue)
      end)

      # ---- Misc ----
      reg.call("error", 1, -1, ->(args : Array(LispValue)) : LispValue do
        buf = String::Builder.new
        msg = args[0]
        if msg.is_a?(LispStr)
          buf << msg.value
        else
          buf << msg.write_string
        end
        (1...args.size).each do |i|
          buf << ' '
          buf << args[i].write_string
        end
        raise LispUserError.new(buf.to_s)
      end)

      reg.call("exit", 0, 1, ->(args : Array(LispValue)) : LispValue do
        code = args.empty? ? 0 : int_arg(args[0], "exit").clamp(0_i64, 255_i64).to_i
        raise LispExit.new(code)
      end)

      # ---- Macros ----
      reg.call("gensym", 0, 1, ->(args : Array(LispValue)) : LispValue do
        prefix = case a = args[0]?
                 when LispStr then a.value
                 when LispSym then a.name
                 when Nil     then "g"
                 else              raise LispRuntimeError.new("gensym: expected a string or symbol prefix")
                 end
        @gensym_counter += 1
        LispSym.of("#{prefix}__#{@gensym_counter}")
      end)
    end

    # ---- I/O helper ----

    private def emit(s : String) : Nil
      @stdout.print(s)
    end

    # ---- Arithmetic helpers ----

    private def num_add(a : LispValue, b : LispValue, who : String) : LispValue
      LISP.num_binop(a, b, who, ->(x : Int64, y : Int64) { x + y }, ->(x : Float64, y : Float64) { x + y })
    end

    private def num_sub(a : LispValue, b : LispValue, who : String) : LispValue
      LISP.num_binop(a, b, who, ->(x : Int64, y : Int64) { x - y }, ->(x : Float64, y : Float64) { x - y })
    end

    private def num_mul(a : LispValue, b : LispValue, who : String) : LispValue
      LISP.num_binop(a, b, who, ->(x : Int64, y : Int64) { x * y }, ->(x : Float64, y : Float64) { x * y })
    end

    private def divide(a : LispValue, b : LispValue) : LispValue
      if a.is_a?(LispInt) && b.is_a?(LispInt)
        raise LispRuntimeError.new("/: division by zero") if b.value == 0
        if a.value % b.value == 0
          LispInt.new(a.value // b.value)
        else
          LispFloat.new(a.value.to_f64 / b.value.to_f64)
        end
      else
        bf = LISP.as_f64(b, "/")
        raise LispRuntimeError.new("/: division by zero") if bf == 0.0
        LispFloat.new(LISP.as_f64(a, "/") / bf)
      end
    end

    private def string_chain_cmp(args : Array(LispValue), who : String, &block : String, String -> Bool) : LispValue
      strs = args.map do |arg|
        raise LispRuntimeError.new("#{who}: expected string, got #{arg.write_string}") unless arg.is_a?(LispStr)
        arg.value
      end
      ok = (0...strs.size - 1).all? { |i| block.call(strs[i], strs[i + 1]) }
      LispBool.of(ok)
    end

    private def int_arg(v : LispValue, who : String) : Int64
      case v
      when LispInt then v.value
      else
        raise LispRuntimeError.new("#{who}: expected integer, got #{v.write_string}")
      end
    end

    private def vector_arg(v : LispValue, who : String) : Array(LispValue)
      raise LispRuntimeError.new("#{who}: expected vector, got #{v.write_string}") unless v.is_a?(LispVector)
      v.value
    end

    private def vector_index_arg(v : LispValue, who : String) : Int32
      raise LispRuntimeError.new("#{who}: expected integer, got #{v.write_string}") unless v.is_a?(LispInt)
      v.value.to_i32
    end

    private def blob_arg(v : LispValue, who : String) : Bytes
      raise LispRuntimeError.new("#{who}: expected blob, got #{v.write_string}") unless v.is_a?(LispBlob)
      v.value
    end

    private def fold_minmax(args : Array(LispValue), who : String, is_min : Bool) : LispValue
      best = args[0]
      unless best.is_a?(LispInt) || best.is_a?(LispFloat)
        raise LispRuntimeError.new("#{who}: expected number, got #{best.write_string}")
      end
      any_float = best.is_a?(LispFloat)
      (1...args.size).each do |i|
        v = args[i]
        unless v.is_a?(LispInt) || v.is_a?(LispFloat)
          raise LispRuntimeError.new("#{who}: expected number, got #{v.write_string}")
        end
        any_float = true if v.is_a?(LispFloat)
        bv = LISP.as_f64(best, who)
        vv = LISP.as_f64(v, who)
        if is_min
          best = v if vv < bv
        else
          best = v if vv > bv
        end
      end
      if any_float && best.is_a?(LispInt)
        LispFloat.new(best.value.to_f64)
      else
        best
      end
    end

    private def num_chain(args : Array(LispValue), who : String, &cmp : Float64, Float64 -> Bool) : LispValue
      prev = LISP.as_f64(args[0], who)
      (1...args.size).each do |i|
        cur = LISP.as_f64(args[i], who)
        return FALSE.as(LispValue) unless cmp.call(prev, cur)
        prev = cur
      end
      TRUE.as(LispValue)
    end
  end
end
