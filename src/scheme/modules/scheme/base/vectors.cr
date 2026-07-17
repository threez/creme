# ===========================================================================
# (scheme base): vectors
# ===========================================================================

module Scheme::Builtins::Vectors
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("vector", min: 0, max: -1)]
  def vector(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeVector.new(args.dup)
  end

  @[Scheme::SchemeFn("make-vector", min: 1, max: 2)]
  def make_vector(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    n = vector_index_arg(args[0], "make-vector")
    raise SchemeRuntimeError.new("make-vector: size must be non-negative") if n < 0
    fill = args.size == 2 ? args[1] : NIL.as(SchemeValue)
    SchemeVector.new(Array.new(n) { fill })
  end

  @[Scheme::SchemeFn("vector-ref", min: 2, max: 2)]
  def vector_ref(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = vector_arg(args[0], "vector-ref")
    i = vector_index_arg(args[1], "vector-ref")
    raise SchemeRuntimeError.new("vector-ref: index #{i} out of range") if i < 0 || i >= v.size
    v[i]
  end

  @[Scheme::SchemeFn("vector-set!", min: 3, max: 3)]
  def vector_set(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = vector_arg(args[0], "vector-set!")
    i = vector_index_arg(args[1], "vector-set!")
    raise SchemeRuntimeError.new("vector-set!: index #{i} out of range") if i < 0 || i >= v.size
    v[i] = args[2]
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("vector-length", min: 1, max: 1)]
  def vector_length(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeInt.new(vector_arg(args[0], "vector-length").size.to_i64)
  end

  @[Scheme::SchemeFn("vector?", min: 1, max: 1)]
  def vector_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(args[0].is_a?(SchemeVector))
  end

  @[Scheme::SchemeFn("vector->list", min: 1, max: 3)]
  def vector_to_list(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    elems = vector_arg(args[0], "vector->list")
    first, last = seq_range_args(elems.size, args[1]?, args[2]?, "vector->list")
    Scheme.a_to_list(elems[first...last])
  end

  @[Scheme::SchemeFn("list->vector", min: 1, max: 1)]
  def list_to_vector(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeVector.new(Scheme.list_to_a(args[0]))
  end

  @[Scheme::SchemeFn("vector-map", min: 2, max: -1)]
  def vector_map(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    f = args[0]
    vectors = args[1..].map { |v| vector_arg(v, "vector-map") }
    minlen = vectors.min_of(&.size)
    result = Array(SchemeValue).new(minlen) { NIL }
    minlen.times do |i|
      call_args = vectors.map { |elems| elems[i] }
      result[i] = interp.apply(f, call_args)
    end
    SchemeVector.new(result)
  end

  @[Scheme::SchemeFn("vector-for-each", min: 2, max: -1)]
  def vector_for_each(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    f = args[0]
    vectors = args[1..].map { |v| vector_arg(v, "vector-for-each") }
    minlen = vectors.min_of(&.size)
    minlen.times do |i|
      call_args = vectors.map { |elems| elems[i] }
      interp.apply(f, call_args)
    end
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("vector-copy", min: 1, max: 3)]
  def vector_copy(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    elems = vector_arg(args[0], "vector-copy")
    first, last = seq_range_args(elems.size, args[1]?, args[2]?, "vector-copy")
    SchemeVector.new(elems[first...last])
  end

  @[Scheme::SchemeFn("vector-copy!", min: 3, max: 5)]
  def vector_copy_bang(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    to = vector_arg(args[0], "vector-copy!")
    at = int_arg(args[1], "vector-copy!").to_i32
    from = vector_arg(args[2], "vector-copy!")
    first, last = seq_range_args(from.size, args[3]?, args[4]?, "vector-copy!")
    segment = from[first...last]
    raise SchemeRuntimeError.new("vector-copy!: destination range out of bounds") if at < 0 || at + segment.size > to.size
    segment.each_with_index { |v, i| to[at + i] = v }
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("vector-fill!", min: 2, max: 4)]
  def vector_fill(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    elems = vector_arg(args[0], "vector-fill!")
    fill = args[1]
    first, last = seq_range_args(elems.size, args[2]?, args[3]?, "vector-fill!")
    (first...last).each { |i| elems[i] = fill }
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("vector-append", min: 0, max: -1)]
  def vector_append(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    result = [] of SchemeValue
    args.each { |v| result.concat(vector_arg(v, "vector-append")) }
    SchemeVector.new(result)
  end
end

module Scheme
  class Interpreter
    private def install_vectors(env : Env) : Array(String)
      register_module(Scheme::Builtins::Vectors, env)
    end
  end
end
