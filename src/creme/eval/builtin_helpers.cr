# ===========================================================================
# Creme::BuiltinHelpers — stateless helpers shared by Interpreter and by
# the Creme::Builtins::* modules
# ===========================================================================
#
# Included by Interpreter (so nothing there changes its own calling
# convention) and by every Creme::Builtins::Xxx module (via `extend self`
# + `include`, so builtin method bodies keep calling these unqualified,
# exactly like the private Interpreter instance methods they replace).
# Only stateless/pure helpers belong here — anything touching Interpreter
# ivars or genuinely Interpreter-instance state stays a method on
# Interpreter itself (public where a Creme::Builtins::* module needs it),
# reached through a builtin method's explicit `interp` parameter.

require "big"

module Creme::BuiltinHelpers
  private def number?(v : SchemeValue) : Bool
    v.is_a?(SchemeInt) || v.is_a?(SchemeBigInt) || v.is_a?(SchemeRational) || v.is_a?(SchemeFloat) || v.is_a?(SchemeComplex)
  end

  def int_arg(v : SchemeValue, who : String) : Int64
    case v
    when SchemeInt    then Creme.checked_i64(v.value, who)
    when SchemeBigInt then Creme.checked_i64(v.value, who)
    else
      raise SchemeRuntimeError.new("#{who}: expected integer, got #{v.write_string}")
    end
  end

  # Like int_arg, but for genuine arithmetic (modulo/quotient/gcd/lcm/...)
  # rather than an index/count/radix — an oversized BigInt is a perfectly
  # valid integer here, so this doesn't narrow to Int64.
  def rat_arg(v : SchemeValue, who : String) : RatInt
    case v
    when SchemeInt    then v.value
    when SchemeBigInt then v.value
    else
      raise SchemeRuntimeError.new("#{who}: expected integer, got #{v.write_string}")
    end
  end

  def vector_arg(v : SchemeValue, who : String) : Array(SchemeValue)
    raise SchemeRuntimeError.new("#{who}: expected vector, got #{v.write_string}") unless v.is_a?(SchemeVector)
    v.value
  end

  def vector_index_arg(v : SchemeValue, who : String) : Int32
    case v
    when SchemeInt    then Creme.checked_i32(v.value, who)
    when SchemeBigInt then Creme.checked_i32(v.value, who)
    else
      raise SchemeRuntimeError.new("#{who}: expected integer, got #{v.write_string}")
    end
  end

  def blob_arg(v : SchemeValue, who : String) : Bytes
    raise SchemeRuntimeError.new("#{who}: expected blob, got #{v.write_string}") unless v.is_a?(SchemeBlob)
    v.value
  end

  # Resolves optional start/end args (R7RS convention: start defaults to
  # 0, end defaults to the sequence's length) into a validated {first,
  # last} pair, shared by every string/vector/bytevector procedure that
  # accepts an optional range.
  def seq_range_args(size : Int32, start_arg : SchemeValue?, end_arg : SchemeValue?, who : String) : {Int32, Int32}
    first = start_arg ? int_arg(start_arg, who).to_i32 : 0
    last = end_arg ? int_arg(end_arg, who).to_i32 : size
    raise SchemeRuntimeError.new("#{who}: range out of bounds") if first < 0 || last > size || first > last
    {first, last}
  end

  def num_add(a : SchemeValue, b : SchemeValue, who : String) : SchemeValue
    return complex_add(to_complex(a, who), to_complex(b, who), who) if a.is_a?(SchemeComplex) || b.is_a?(SchemeComplex)
    Creme.num_binop3(a, b, who,
      ->(x : RatInt, y : RatInt) { Creme.int_value(Creme.rat_add(x, y)) },
      ->(x : {RatInt, RatInt}, y : {RatInt, RatInt}) { SchemeRational.make(Creme.rat_add(Creme.rat_mul(x[0], y[1]), Creme.rat_mul(y[0], x[1])), Creme.rat_mul(x[1], y[1])) },
      ->(x : Float64, y : Float64) { x + y })
  end

  def num_sub(a : SchemeValue, b : SchemeValue, who : String) : SchemeValue
    return complex_sub(to_complex(a, who), to_complex(b, who), who) if a.is_a?(SchemeComplex) || b.is_a?(SchemeComplex)
    Creme.num_binop3(a, b, who,
      ->(x : RatInt, y : RatInt) { Creme.int_value(Creme.rat_sub(x, y)) },
      ->(x : {RatInt, RatInt}, y : {RatInt, RatInt}) { SchemeRational.make(Creme.rat_sub(Creme.rat_mul(x[0], y[1]), Creme.rat_mul(y[0], x[1])), Creme.rat_mul(x[1], y[1])) },
      ->(x : Float64, y : Float64) { x - y })
  end

  def num_mul(a : SchemeValue, b : SchemeValue, who : String) : SchemeValue
    return complex_mul(to_complex(a, who), to_complex(b, who), who) if a.is_a?(SchemeComplex) || b.is_a?(SchemeComplex)
    Creme.num_binop3(a, b, who,
      ->(x : RatInt, y : RatInt) { Creme.int_value(Creme.rat_mul(x, y)) },
      ->(x : {RatInt, RatInt}, y : {RatInt, RatInt}) { SchemeRational.make(Creme.rat_mul(x[0], y[0]), Creme.rat_mul(x[1], y[1])) },
      ->(x : Float64, y : Float64) { x * y })
  end

  # base ** exp for exp >= 0, escaping to BigInt when Int64 would
  # overflow (mirrors Creme.rat_mul/rat_add's own escape). Shared by
  # expt's positive-exponent path and its negative-exponent path (which
  # negates the exponent, computes the positive power, then routes the
  # result through SchemeRational.make as a reciprocal).
  def expt_int_pow(base : RatInt, exp : Int64) : RatInt
    result = 1_i64.as(RatInt)
    exp.times { result = Creme.rat_mul(result, base) }
    result
  end

  # Integer square root of a non-negative RatInt: {floor(sqrt(n)), n -
  # floor(sqrt(n))**2}. A zero remainder means n is a perfect square. The
  # initial Float64 guess can be off (rounding, or for a BigInt n whose
  # magnitude exceeds Float64's exact integer range) but the correction
  # loops below fix that unconditionally regardless of magnitude, since
  # they only ever move the guess by relative single steps. Shared by
  # sqrt's exact fast path and the exact-integer-sqrt builtin.
  def exact_integer_sqrt_pair(n : RatInt) : {RatInt, RatInt}
    return {0_i64, 0_i64} if n == 0
    root = Creme.rat_demote(Math.sqrt(n.to_f64).to_big_i)
    # Float64 sqrt can be off by one (or more, for a huge BigInt) at the
    # boundary; correct it.
    while Creme.rat_mul(Creme.rat_add(root, 1_i64), Creme.rat_add(root, 1_i64)) <= n
      root = Creme.rat_add(root, 1_i64)
    end
    while Creme.rat_mul(root, root) > n
      root = Creme.rat_sub(root, 1_i64)
    end
    {root, Creme.rat_sub(n, Creme.rat_mul(root, root))}
  end

  # inexact->exact / exact on a SchemeInt/SchemeRational is the identity
  # (already exact); on a SchemeFloat, decomposes the IEEE-754 double
  # into an exact numerator/denominator via Crystal's BigRational (which
  # already handles the exponent/subnormal decomposition correctly, so
  # this doesn't hand-roll bit manipulation) — BigRational's numerator/
  # denominator are already BigInt, so this can no longer overflow; the
  # old downcast-to-Int64/rescue is gone.
  def to_exact(v : SchemeValue) : SchemeValue
    return v if v.is_a?(SchemeInt) || v.is_a?(SchemeBigInt) || v.is_a?(SchemeRational)
    raise SchemeRuntimeError.new("exact: expected number, got #{v.write_string}") unless v.is_a?(SchemeFloat)
    raise SchemeRuntimeError.new("exact: cannot convert a non-finite float") unless v.value.finite?
    r = BigRational.new(v.value)
    SchemeRational.make(r.numerator, r.denominator)
  end

  def round_like(v : SchemeValue, who : String, rational_op : RatInt, RatInt -> RatInt, &block : Float64 -> Float64) : SchemeValue
    case v
    when SchemeInt      then v
    when SchemeBigInt   then v
    when SchemeRational then Creme.int_value(rational_op.call(v.numerator, v.denominator))
    when SchemeFloat    then SchemeFloat.new(block.call(v.value))
    else                     raise SchemeRuntimeError.new("#{who}: expected number, got #{v.write_string}")
    end
  end

  # Exact floor/ceiling/truncate/round on a reduced rational n/d (d > 0,
  # per SchemeRational.make's own invariant) — staying exact throughout,
  # since going through Float64 could lose precision or overflow for
  # large numerators/denominators. Crystal's // is floor division, so
  # floor is a one-liner; the other three build on it. Each op stays
  # within RatInt (int_div/rat_* already escape to BigInt as needed).
  def rational_floor(n : RatInt, d : RatInt) : RatInt
    Creme.int_div(n, d)
  end

  def rational_ceiling(n : RatInt, d : RatInt) : RatInt
    Creme.rat_sub(0_i64, Creme.int_div(Creme.rat_sub(0_i64, n), d))
  end

  def rational_truncate(n : RatInt, d : RatInt) : RatInt
    n.sign < 0 ? rational_ceiling(n, d) : rational_floor(n, d)
  end

  # Round-half-to-even: compare the fractional part against 1/2 by
  # cross-multiplication (2 * remainder vs d) to stay in exact integer
  # arithmetic, then break an exact tie by rounding to the even quotient.
  def rational_round(n : RatInt, d : RatInt) : RatInt
    q = rational_floor(n, d)
    r = Creme.rat_sub(n, Creme.rat_mul(q, d))
    twice_r = Creme.rat_mul(r, 2_i64)
    if twice_r < d
      q
    elsif twice_r > d
      Creme.rat_add(q, 1_i64)
    else
      q.even? ? q : Creme.rat_add(q, 1_i64)
    end
  end

  # Exact/exact division produces an exact SchemeRational (auto-collapsing
  # to SchemeInt when it divides evenly) instead of falling back to an
  # inexact float — e.g. (/ 1 3) yields exact 1/3, not 0.333...
  # Division by an exact zero always raises. Division by an inexact
  # (float) zero instead follows IEEE-754 float semantics, producing
  # +inf.0/-inf.0/+nan.0 as appropriate — Crystal's native Float64
  # division already does the right thing here.
  def divide(a : SchemeValue, b : SchemeValue) : SchemeValue
    return complex_div(to_complex(a, "/"), to_complex(b, "/")) if a.is_a?(SchemeComplex) || b.is_a?(SchemeComplex)
    rank = Math.max(Creme.num_rank(a, "/"), Creme.num_rank(b, "/"))
    if rank <= 1
      an, ad = Creme.as_ratio(a)
      bn, bd = Creme.as_ratio(b)
      raise SchemeRuntimeError.new("/: division by zero") if bn == 0
      SchemeRational.make(Creme.rat_mul(an, bd), Creme.rat_mul(ad, bn))
    else
      bf = Creme.as_f64(b, "/")
      SchemeFloat.new(Creme.as_f64(a, "/") / bf)
    end
  end

  # ameba:disable Metrics/CyclomaticComplexity
  def fold_minmax(args : Array(SchemeValue), who : String, is_min : Bool) : SchemeValue
    best = args[0]
    unless best.is_a?(SchemeInt) || best.is_a?(SchemeBigInt) || best.is_a?(SchemeFloat)
      raise SchemeRuntimeError.new("#{who}: expected number, got #{best.write_string}")
    end
    any_float = best.is_a?(SchemeFloat)
    (1...args.size).each do |i|
      v = args[i]
      unless v.is_a?(SchemeInt) || v.is_a?(SchemeBigInt) || v.is_a?(SchemeFloat)
        raise SchemeRuntimeError.new("#{who}: expected number, got #{v.write_string}")
      end
      any_float = true if v.is_a?(SchemeFloat)
      bv = Creme.as_f64(best, who)
      vv = Creme.as_f64(v, who)
      if is_min
        best = v if vv < bv
      else
        best = v if vv > bv
      end
    end
    if any_float && !best.is_a?(SchemeFloat)
      SchemeFloat.new(Creme.as_f64(best, who))
    else
      best
    end
  end

  # Three-way exact comparison (-1, 0, 1) between two exact numbers (int,
  # bigint, or rational), via cross-multiplication in BigInt so large
  # numerator/denominator pairs can't silently overflow Int64 mid-
  # comparison — this widening is purely internal, a BigInt never becomes
  # a Scheme-visible value on its own (only ever wrapped in a SchemeBigInt).
  private def exact_compare(a : SchemeValue, b : SchemeValue) : Int32
    # Fast path: two plain ints compare natively, no BigInt promotion.
    if a.is_a?(SchemeInt) && b.is_a?(SchemeInt)
      return a.value <=> b.value
    end
    an, ad = Creme.as_ratio(a)
    bn, bd = Creme.as_ratio(b)
    lhs = Creme.to_big_i(an) * Creme.to_big_i(bd)
    rhs = Creme.to_big_i(bn) * Creme.to_big_i(ad)
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
  def num_chain(args : Array(SchemeValue), who : String, &cmp : Int32 -> Bool) : SchemeValue
    (0...args.size - 1).each do |i|
      cmp_result = num_compare2(args[i], args[i + 1], who)
      return FALSE.as(SchemeValue) if cmp_result.nil? || !cmp.call(cmp_result)
    end
    TRUE.as(SchemeValue)
  end

  # Compare two numbers: -1/0/1, or nil if incomparable (a NaN). Shared by
  # num_chain and the AST's inlined comparison primitives (PrimCallNode).
  def num_compare2(a : SchemeValue, b : SchemeValue, who : String) : Int32?
    if Creme.exact?(a) && Creme.exact?(b)
      exact_compare(a, b)
    else
      Creme.as_f64(a, who) <=> Creme.as_f64(b, who)
    end
  end

  def real_component_arg(v : SchemeValue, who : String) : RealComponent
    case v
    when SchemeInt, SchemeBigInt, SchemeRational, SchemeFloat then v
    else
      raise SchemeRuntimeError.new("#{who}: expected a real number, got #{v.write_string}")
    end
  end

  # Promotes a real numeric value to a zero-imaginary SchemeComplex, for
  # mixed complex/real arithmetic. Raises the normal "expected number"
  # error for anything non-numeric.
  def to_complex(v : SchemeValue, who : String) : SchemeComplex
    return v if v.is_a?(SchemeComplex)
    SchemeComplex.wrap(real_component_arg(v, who), SchemeInt.new(0_i64))
  end

  # Extracts a (re, im) Float64 pair for the complex-aware transcendentals
  # (Creme::ComplexMath, complex_math.cr) — a real value promotes with
  # im = 0.0, mirroring to_complex's own real->complex promotion.
  def complex_parts(v : SchemeValue, who : String) : {Float64, Float64}
    if v.is_a?(SchemeComplex)
      {Creme.as_f64(v.real, who), Creme.as_f64(v.imag, who)}
    else
      {Creme.as_f64(v, who), 0.0}
    end
  end

  def complex_result(re : Float64, im : Float64) : SchemeValue
    SchemeComplex.make(SchemeFloat.new(re), SchemeFloat.new(im))
  end

  # Whether v is an exact integer, or a float with no fractional part —
  # used by expt to decide whether a negative real base still yields a
  # real result (integer-valued exponent) or must go complex.
  def integer_valued?(v : SchemeValue) : Bool
    case v
    when SchemeInt, SchemeBigInt then true
    when SchemeFloat             then v.value.finite? && v.value == v.value.round
    else                              false
    end
  end

  def complex_add(a : SchemeComplex, b : SchemeComplex, who : String) : SchemeValue
    SchemeComplex.make(num_add(a.real, b.real, who).as(RealComponent), num_add(a.imag, b.imag, who).as(RealComponent))
  end

  def complex_sub(a : SchemeComplex, b : SchemeComplex, who : String) : SchemeValue
    SchemeComplex.make(num_sub(a.real, b.real, who).as(RealComponent), num_sub(a.imag, b.imag, who).as(RealComponent))
  end

  def complex_mul(a : SchemeComplex, b : SchemeComplex, who : String) : SchemeValue
    # (a.re + a.im*i)(b.re + b.im*i) = (a.re*b.re - a.im*b.im) + (a.re*b.im + a.im*b.re)*i
    re = num_sub(num_mul(a.real, b.real, who), num_mul(a.imag, b.imag, who), who)
    im = num_add(num_mul(a.real, b.imag, who), num_mul(a.imag, b.real, who), who)
    SchemeComplex.make(re.as(RealComponent), im.as(RealComponent))
  end

  def string_arg(v : SchemeValue, who : String) : String
    raise SchemeRuntimeError.new("#{who}: expected string, got #{v.write_string}") unless v.is_a?(SchemeStr)
    v.value
  end

  # Same check as string_arg — kept as a distinct name since (creme string)
  # and (scheme char) originated it separately; not consolidated here to
  # avoid changing anything beyond relocation.
  def string_ext_arg(v : SchemeValue, who : String) : String
    raise SchemeRuntimeError.new("#{who}: expected string, got #{v.write_string}") unless v.is_a?(SchemeStr)
    v.value
  end

  def radix_arg(v : SchemeValue?, who : String) : Int32
    return 10 unless v
    r = int_arg(v, who)
    raise SchemeRuntimeError.new("#{who}: radix must be 2, 8, 10, or 16") unless {2_i64, 8_i64, 10_i64, 16_i64}.includes?(r)
    r.to_i32
  end

  def environment_specifier_arg(v : SchemeValue, who : String) : Env
    case v
    when SchemeEnvironment then v.env
    else                        raise SchemeRuntimeError.new("#{who}: expected an environment specifier, got #{v.write_string}")
    end
  end

  # Unwraps a producer expression's result for an N-way binding form
  # (let-values, let*-values, define-values, call-with-values): a (values a
  # b ...) result (an actual SchemeValues, per its own transparent-outside-
  # call-with-values contract) unwraps to its items; anything else is
  # treated as a single value.
  def values_to_a(v : SchemeValue) : Array(SchemeValue)
    return v.items if v.is_a?(SchemeValues)
    [v] of SchemeValue
  end

  def byte_arg(v : SchemeValue, who : String) : UInt8
    n = int_arg(v, who)
    raise SchemeRuntimeError.new("#{who}: expected a byte (0..255), got #{v.write_string}") unless n >= 0 && n <= 255
    n.to_u8
  end

  def port_arg(v : SchemeValue, who : String) : SchemePort
    raise SchemeRuntimeError.new("#{who}: expected a port, got #{v.write_string}") unless v.is_a?(SchemePort)
    v
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
  def write_shared_string(v : SchemeValue) : String
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

  # Reads and parses one datum from `p`, then puts back whatever's left
  # unread so a subsequent `read` on the same port continues where this
  # one stopped. See the `read` builtin's registration comment for why
  # this re-tokenizes the whole remaining buffer rather than reading
  # incrementally.
  def read_one_form(p : SchemePort) : SchemeValue
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

  # a/b = a * conj(b) / |b|^2 — stays exact when every component is
  # exact, since |b|^2 (real^2 + imag^2) and every numerator product are
  # computed via num_mul/num_add/num_sub (which already preserve
  # exactness) and the final divide by that exact rational denom does
  # too — same precedent as complex_add/sub/mul above, which already
  # stay exact. Only falls back to inexact when an operand's component
  # already is (routed through the ordinary real `divide`, same as any
  # other real division).
  def complex_div(a : SchemeComplex, b : SchemeComplex) : SchemeValue
    denom = num_add(num_mul(b.real, b.real, "/"), num_mul(b.imag, b.imag, "/"), "/")
    raise SchemeRuntimeError.new("/: division by zero") if Creme.as_f64(denom, "/") == 0.0
    re = num_add(num_mul(a.real, b.real, "/"), num_mul(a.imag, b.imag, "/"), "/")
    im = num_sub(num_mul(a.imag, b.real, "/"), num_mul(a.real, b.imag, "/"), "/")
    SchemeComplex.make(divide(re, denom).as(RealComponent), divide(im, denom).as(RealComponent))
  end
end
