# ===========================================================================
# (scheme base): pairs & lists
# ===========================================================================

module Scheme::Builtins::PairsLists
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("cons", min: 2, max: 2)]
  def cons(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    Cons.new(args[0], args[1]).as(SchemeValue)
  end

  @[Scheme::SchemeFn("car", min: 1, max: 1)]
  def car(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("car: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v.car
  end

  @[Scheme::SchemeFn("cdr", min: 1, max: 1)]
  def cdr(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("cdr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v.cdr
  end

  # The four 2-level compositions R7RS scopes to (scheme base) (the 3-/4-level
  # ones live in (scheme cxr)/cxr.cr). Real builtins rather than prelude
  # closures so a direct `(cadr x)` fuses into Op::Cxr (the analyzer fuses any
  # call whose head resolves to a cxr-named builtin — see analyzer's cxr_name?
  # / bytecode_compiler's cxr_code); each raises the same "<name>: expected
  # pair" error the fused op's deopt path reproduces.
  @[Scheme::SchemeFn("caar", min: 1, max: 1)]
  def caar(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("caar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("caar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v.car
  end

  @[Scheme::SchemeFn("cadr", min: 1, max: 1)]
  def cadr(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("cadr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("cadr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v.car
  end

  @[Scheme::SchemeFn("cdar", min: 1, max: 1)]
  def cdar(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("cdar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.car
    raise SchemeRuntimeError.new("cdar: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v.cdr
  end

  @[Scheme::SchemeFn("cddr", min: 1, max: 1)]
  def cddr(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("cddr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v = v.cdr
    raise SchemeRuntimeError.new("cddr: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v.cdr
  end

  @[Scheme::SchemeFn("set-car!", min: 2, max: 2)]
  def set_car(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("set-car!: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v.car = args[1]
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("set-cdr!", min: 2, max: 2)]
  def set_cdr(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    raise SchemeRuntimeError.new("set-cdr!: expected pair, got #{v.write_string}") unless v.is_a?(Cons)
    v.cdr = args[1]
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("list", min: 0, max: -1)]
  def list(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    Scheme.a_to_list(args)
  end

  @[Scheme::SchemeFn("append", min: 0, max: -1)]
  def append(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    return NIL.as(SchemeValue) if args.empty?
    result = args[args.size - 1]
    i = args.size - 2
    while i >= 0
      elems = Scheme.list_to_a(args[i])
      result = Scheme.a_to_list(elems, result)
      i -= 1
    end
    result
  end

  @[Scheme::SchemeFn("length", min: 1, max: 1)]
  def length(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeInt.new(Scheme.list_to_a(args[0]).size.to_i64)
  end

  @[Scheme::SchemeFn("reverse", min: 1, max: 1)]
  def reverse(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    elems = Scheme.list_to_a(args[0])
    Scheme.a_to_list(elems.reverse)
  end

  @[Scheme::SchemeFn("list-ref", min: 2, max: 2)]
  def list_ref(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    elems = Scheme.list_to_a(args[0])
    idx = int_arg(args[1], "list-ref")
    if idx < 0 || idx >= elems.size
      raise SchemeRuntimeError.new("list-ref: index #{idx} out of range")
    end
    elems[idx]
  end

  @[Scheme::SchemeFn("null?", min: 1, max: 1)]
  def null_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(args[0].is_a?(SchemeNil))
  end

  @[Scheme::SchemeFn("pair?", min: 1, max: 1)]
  def pair_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(args[0].is_a?(Cons))
  end

  @[Scheme::SchemeFn("list?", min: 1, max: 1)]
  def list_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(Scheme.proper_list?(args[0]))
  end

  # list-copy/list-set! moved to Scheme source in (scheme base)'s own
  # scheme-defined layer — see install_scheme_base_and_write_libraries in
  # base.cr — since both are trivially expressible in terms of other
  # (scheme base) primitives (pair?/car/cdr/cons, set-car!/list-tail).

  @[Scheme::SchemeFn("list-tail", min: 2, max: 2)]
  def list_tail(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    idx = int_arg(args[1], "list-tail")
    raise SchemeRuntimeError.new("list-tail: index #{idx} out of range") if idx < 0
    cur = args[0]
    idx.times do
      raise SchemeRuntimeError.new("list-tail: index out of range") unless cur.is_a?(Cons)
      cur = cur.cdr
    end
    cur
  end

  @[Scheme::SchemeFn("make-list", min: 1, max: 2)]
  def make_list(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    n = int_arg(args[0], "make-list")
    raise SchemeRuntimeError.new("make-list: expected a non-negative length") if n < 0
    fill = args[1]? || NIL
    Scheme.a_to_list(Array.new(n.to_i32, fill))
  end

  # assq/assv/memq/memv use eq?/eqv? identity comparison; assoc/member
  # default to equal? but accept an optional comparator procedure.
  @[Scheme::SchemeFn("assq", min: 2, max: 2)]
  def assq(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    assoc_impl(interp, args[0], args[1], nil, use_eqv: true)
  end

  @[Scheme::SchemeFn("assv", min: 2, max: 2)]
  def assv(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    assoc_impl(interp, args[0], args[1], nil, use_eqv: true)
  end

  @[Scheme::SchemeFn("assoc", min: 2, max: 3)]
  def assoc(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    assoc_impl(interp, args[0], args[1], args[2]?, use_eqv: false)
  end

  @[Scheme::SchemeFn("memq", min: 2, max: 2)]
  def memq(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    member_impl(interp, args[0], args[1], nil, use_eqv: true)
  end

  @[Scheme::SchemeFn("memv", min: 2, max: 2)]
  def memv(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    member_impl(interp, args[0], args[1], nil, use_eqv: true)
  end

  @[Scheme::SchemeFn("member", min: 2, max: 3)]
  def member(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    member_impl(interp, args[0], args[1], args[2]?, use_eqv: false)
  end

  # Shared by assq/assv (use_eqv: true, no comparator) and assoc (use_eqv:
  # false, equal? by default, or a caller-supplied 2-arg predicate).
  private def assoc_impl(interp : Interpreter, key : SchemeValue, alist : SchemeValue, comparator : SchemeValue?, use_eqv : Bool) : SchemeValue
    matches = ->(candidate : SchemeValue) : Bool do
      if comparator
        Scheme.truthy?(interp.apply(comparator, [key, candidate] of SchemeValue))
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

  private def member_impl(interp : Interpreter, x : SchemeValue, lst : SchemeValue, comparator : SchemeValue?, use_eqv : Bool) : SchemeValue
    matches = ->(candidate : SchemeValue) : Bool do
      if comparator
        Scheme.truthy?(interp.apply(comparator, [x, candidate] of SchemeValue))
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
end

module Scheme
  class Interpreter
    private def install_pairs_and_lists(env : Env) : Array(String)
      register_module(Scheme::Builtins::PairsLists, env)
    end
  end
end
