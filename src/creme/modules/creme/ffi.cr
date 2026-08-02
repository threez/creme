# ===========================================================================
# (creme ffi): a generic dlopen/libffi foreign-function bridge
# ===========================================================================
#
# Lets Scheme code call an arbitrary native C function by name/signature at
# runtime, instead of needing a hand-written native module (like every
# other file in this directory) per library. Backed by ffi_shim.cr/.o (see
# that file's own header comment for why a small precompiled C shim exists
# at all). Mirrors icecreme/creme_ffi.c's own Scheme-facing surface exactly —
# same procedure names, same MVP type-marshalling scope — so a script using
# (creme ffi) behaves identically under native `bin/creme` and `--emit-icecreme`/
# icecreme/icecreme:
#
#   (define lib (ffi-open "libm.so.6"))
#   (define fn (ffi-function lib "sqrt" 'double '(double)))
#   (ffi-call fn (list 4.0))  ; => 2.0
#   (ffi-close lib)
#   (ffi-pointer-ref ptr offset 'int32)      ; read a struct field
#   (ffi-pointer-set! ptr offset 'int32 42)  ; write a struct field
#   (ffi-type-size 'int32)                   ; => 4
#   (ffi-gc-malloc 16)                       ; GC-owned scratch pointer
#   (ffi-gc-free ptr)                        ; optional early release
#
# MVP type symbols: void (return only, and not valid for
# ffi-pointer-ref/-set!), int32, int64, double, bool, string (char*,
# copy-in/copy-out), pointer (an opaque handle round-tripped through a
# SchemeBox, e.g. to pass a previous call's returned pointer into a later
# call). NOT supported, by design: passing/returning a whole struct BY
# VALUE as a single ffi-call argument/return value (there's no type
# symbol for "struct"), and passing a Scheme closure as a C callback (a
# function pointer INTO Scheme) — see icecreme/creme_ffi.c's own header
# comment for the same two documented non-goals. ffi-pointer-ref/
# ffi-pointer-set! DO let a script read/write an individual struct FIELD,
# given a pointer to the struct and that field's byte offset — but this
# bridge never computes a struct's layout (alignment/padding) for you;
# offsets/sizes must come from the real C ABI being targeted, same as
# (creme foreign)'s define-foreign-struct macro documents. ffi-gc-malloc
# gives a script scratch memory backed by THIS process's own Boehm GC heap
# (the same allocator every other Crystal object already lives in) instead
# of libc's malloc, reclaimed automatically once unreachable, no matching
# free ever required; ffi-gc-free is an optional early release, valid ONLY
# on a pointer ffi-gc-malloc itself returned (never on a libc-malloc'd
# pointer or one a C function handed back, e.g. a FILE*) — see its own
# method doc comment for why.
#
# SECURITY: this hands a guest script genuine native code execution —
# ffi-pointer-ref/-set! are raw offset+type memory access with no bounds
# checking whatsoever, and ffi-gc-free on the wrong pointer corrupts the
# GC's own heap bookkeeping, on top of the usual "bad signature corrupts
# the stack/heap" risk every other call here already carries — an embedder
# MUST exclude "creme ffi" from any allowed_libraries allowlist for
# untrusted guest scripts (Interpreter#allowed_libraries,
# src/creme/eval/import.cr), exactly like the FFI-heavy libraries
# documented there already (tui/rfc8439/raft/jose/etc.).
require "./ffi_shim"

module Creme::Builtins::FfiLibrary
  extend self
  include Creme::BuiltinHelpers

  private KIND_NAMES = {
    "void"    => Creme::CremeFfiShim::KIND_VOID,
    "int32"   => Creme::CremeFfiShim::KIND_INT32,
    "int64"   => Creme::CremeFfiShim::KIND_INT64,
    "double"  => Creme::CremeFfiShim::KIND_DOUBLE,
    "bool"    => Creme::CremeFfiShim::KIND_BOOL,
    "string"  => Creme::CremeFfiShim::KIND_STRING,
    "pointer" => Creme::CremeFfiShim::KIND_POINTER,
  }

  private def kind_of(v : SchemeValue, who : String) : Int32
    raise SchemeRuntimeError.new("#{who}: expected a type symbol") unless v.is_a?(SchemeSym)
    KIND_NAMES[v.name]? || raise SchemeRuntimeError.new(
      "#{who}: unknown ffi type '#{v.name}' (expected void/int32/int64/double/bool/string/pointer)")
  end

  # One prepared ffi-function: a libffi call handle (ffi_shim.cr's opaque
  # `Void*`), the dlopen handle it was resolved against (kept alive here
  # only so it isn't GC'd early — dlclose is still the caller's own
  # responsibility via ffi-close, matching icecreme's identical lifetime
  # contract), and the per-argument/return type kinds ffi-call needs to
  # marshal Scheme values in and out.
  private class PreparedFn
    getter prepared : Void*
    getter ret_kind : Int32
    getter arg_kinds : Array(Int32)

    def initialize(@prepared : Void*, @ret_kind : Int32, @arg_kinds : Array(Int32))
    end
  end

  @[Creme::SchemeFn("ffi-open", min: 1, max: 1)]
  def ffi_open(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    raise SchemeRuntimeError.new("ffi-open: expected a library path/name string") unless (path = args[0]).is_a?(SchemeStr)
    handle = Creme::CremeFfiShim.dlopen(path.value)
    SchemeBox.new("ffi-lib", handle, "#<ffi-lib:#{path.value}>")
  end

  @[Creme::SchemeFn("ffi-close", min: 1, max: 1)]
  def ffi_close(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    handle = ffi_lib_arg(args[0], "ffi-close")
    Creme::CremeFfiShim.dlclose(handle)
    NIL
  end

  @[Creme::SchemeFn("ffi-function", min: 4, max: 4)]
  def ffi_function(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    handle = ffi_lib_arg(args[0], "ffi-function")
    raise SchemeRuntimeError.new("ffi-function: expected a function name string") unless (name = args[1]).is_a?(SchemeStr)
    ret_kind = kind_of(args[2], "ffi-function")
    arg_kinds = Creme.list_to_a(args[3]).map { |type_sym| kind_of(type_sym, "ffi-function") }

    prepared = Creme::CremeFfiShim.prepare(handle, name.value, ret_kind, arg_kinds)
    SchemeBox.new("ffi-func", PreparedFn.new(prepared, ret_kind, arg_kinds), "#<ffi-func:#{name.value}>")
  end

  @[Creme::SchemeFn("ffi-call", min: 2, max: 2)]
  def ffi_call(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    raise SchemeRuntimeError.new("ffi-call: expected a value from ffi-function") unless (box = args[0]).is_a?(SchemeBox) && box.tag == "ffi-func"
    fn = box.get(PreparedFn)
    given = Creme.list_to_a(args[1])
    raise SchemeRuntimeError.new("ffi-call: expected #{fn.arg_kinds.size} argument(s), got #{given.size}") unless given.size == fn.arg_kinds.size

    # One 8-byte slot per argument (enough for every MVP scalar kind) plus
    # one more for the return value, all in one Crystal-GC-owned buffer —
    # ffi_shim.cr's invoke just needs a `Void**` of per-argument pointers
    # and one `Void*` for the return slot; nothing here needs to survive
    # past this call.
    slots = Pointer(UInt8).malloc(8_u64 * (fn.arg_kinds.size + 1))
    arg_ptrs = Pointer(Void*).malloc(Math.max(fn.arg_kinds.size, 1).to_u64)
    fn.arg_kinds.each_with_index do |kind, i|
      slot = (slots + 8 * i).as(Void*)
      arg_ptrs[i] = slot
      marshal_arg_into(given[i], kind, slot, "ffi-call")
    end
    ret_slot = (slots + 8 * fn.arg_kinds.size).as(Void*)

    Creme::CremeFfiShim.invoke(fn.prepared, arg_ptrs, ret_slot)
    marshal_return(fn.ret_kind, ret_slot)
  end

  @[Creme::SchemeFn("ffi-pointer-ref", min: 3, max: 3)]
  def ffi_pointer_ref(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    base = ffi_pointer_base_arg(args[0], "ffi-pointer-ref")
    raise SchemeRuntimeError.new("ffi-pointer-ref: expected an integer offset") unless (off = args[1]).is_a?(SchemeInt)
    kind = kind_of(args[2], "ffi-pointer-ref")
    raise SchemeRuntimeError.new("ffi-pointer-ref: type must not be void") if kind == Creme::CremeFfiShim::KIND_VOID
    marshal_return(kind, (base + off.value).as(Void*))
  end

  @[Creme::SchemeFn("ffi-pointer-set!", min: 4, max: 4)]
  def ffi_pointer_set(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    base = ffi_pointer_base_arg(args[0], "ffi-pointer-set!")
    raise SchemeRuntimeError.new("ffi-pointer-set!: expected an integer offset") unless (off = args[1]).is_a?(SchemeInt)
    kind = kind_of(args[2], "ffi-pointer-set!")
    raise SchemeRuntimeError.new("ffi-pointer-set!: type must not be void") if kind == Creme::CremeFfiShim::KIND_VOID
    marshal_arg_into(args[3], kind, (base + off.value).as(Void*), "ffi-pointer-set!")
    NIL
  end

  @[Creme::SchemeFn("ffi-type-size", min: 1, max: 1)]
  def ffi_type_size(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    kind = kind_of(args[0], "ffi-type-size")
    size = case kind
           when Creme::CremeFfiShim::KIND_INT32, Creme::CremeFfiShim::KIND_BOOL
             4
           when Creme::CremeFfiShim::KIND_INT64, Creme::CremeFfiShim::KIND_DOUBLE,
                Creme::CremeFfiShim::KIND_STRING, Creme::CremeFfiShim::KIND_POINTER
             8
           else
             raise SchemeRuntimeError.new("ffi-type-size: 'void has no size")
           end
    SchemeInt.new(size.to_i64)
  end

  # Scratch memory allocated through THIS process's own Boehm GC heap (the
  # same allocator every other Crystal object already lives in), instead of
  # libc's malloc -- Pointer(UInt8).malloc is itself GC-managed and
  # zero-initialized (the exact idiom ffi-call's own argument slots already
  # use, above). Reclaimed automatically once the returned pointer becomes
  # unreachable -- no matching free is ever REQUIRED, unlike a libc-malloc'd
  # buffer.
  @[Creme::SchemeFn("ffi-gc-malloc", min: 1, max: 1)]
  def ffi_gc_malloc(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    raise SchemeRuntimeError.new("ffi-gc-malloc: expected a non-negative size") unless (n = args[0]).is_a?(SchemeInt) && n.value >= 0
    ptr = Pointer(UInt8).malloc(n.value.to_u64).as(Void*)
    SchemeBox.new("ffi-pointer", ptr, "#<ffi-pointer>")
  end

  # An OPTIONAL early release of memory ffi-gc-malloc itself returned, so a
  # script can hand a large buffer back before the next collection cycle
  # would otherwise reclaim it. Only ever valid on a pointer ffi-gc-malloc
  # returned -- calling this on a libc-malloc'd pointer, or one a C
  # function handed back (a FILE*, a sqlite3*, ...), corrupts Boehm's own
  # heap bookkeeping, exactly as calling libc's free() on memory it didn't
  # allocate would. After this call the pointer must never be
  # read/written/passed to another call again -- the same use-after-free
  # risk as any manual C memory management, consistent with this bridge's
  # existing no-bounds-checking SECURITY posture.
  @[Creme::SchemeFn("ffi-gc-free", min: 1, max: 1)]
  def ffi_gc_free(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    ptr = ffi_pointer_base_arg(args[0], "ffi-gc-free")
    GC.free(ptr.as(Void*))
    NIL
  end

  @[Creme::SchemeFn("ffi-lib?", min: 1, max: 1)]
  def ffi_lib_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    SchemeBool.of(v.is_a?(SchemeBox) && v.tag == "ffi-lib")
  end

  @[Creme::SchemeFn("ffi-function?", min: 1, max: 1)]
  def ffi_function_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    SchemeBool.of(v.is_a?(SchemeBox) && v.tag == "ffi-func")
  end

  @[Creme::SchemeFn("ffi-pointer?", min: 1, max: 1)]
  def ffi_pointer_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    SchemeBool.of(v.is_a?(SchemeBox) && v.tag == "ffi-pointer")
  end

  @[Creme::SchemeFn("ffi-null-pointer?", min: 1, max: 1)]
  def ffi_null_pointer_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    raise SchemeRuntimeError.new("ffi-null-pointer?: expected a pointer") unless (v = args[0]).is_a?(SchemeBox) && v.tag == "ffi-pointer"
    SchemeBool.of(v.get(Pointer(Void)).null?)
  end

  private def ffi_lib_arg(v : SchemeValue, who : String) : Void*
    raise SchemeRuntimeError.new("#{who}: expected a value from ffi-open") unless v.is_a?(SchemeBox) && v.tag == "ffi-lib"
    v.get(Pointer(Void))
  end

  # Shared by ffi-pointer-ref/ffi-pointer-set! -- extracts the raw base
  # pointer a struct-field access starts from, rejecting both a
  # non-pointer argument and a NULL one (dereferencing NULL is
  # definitionally a crash; this is the one guard against the single
  # most common mistake, not a general safety net -- an arbitrary
  # offset+type still reads/writes anywhere, same as real C).
  private def ffi_pointer_base_arg(v : SchemeValue, who : String) : Pointer(UInt8)
    raise SchemeRuntimeError.new("#{who}: pointer is null") if v.is_a?(SchemeBool) && !v.value?
    raise SchemeRuntimeError.new("#{who}: expected a pointer argument") unless v.is_a?(SchemeBox) && v.tag == "ffi-pointer"
    ptr = v.get(Pointer(Void))
    raise SchemeRuntimeError.new("#{who}: pointer is null") if ptr.null?
    ptr.as(Pointer(UInt8))
  end

  # ameba:disable Metrics/CyclomaticComplexity
  private def marshal_arg_into(v : SchemeValue, kind : Int32, slot : Void*, who : String) : Nil
    case kind
    when Creme::CremeFfiShim::KIND_INT32
      raise SchemeRuntimeError.new("#{who}: expected an integer argument") unless v.is_a?(SchemeInt)
      slot.as(Int32*).value = v.value.to_i32
    when Creme::CremeFfiShim::KIND_INT64
      raise SchemeRuntimeError.new("#{who}: expected an integer argument") unless v.is_a?(SchemeInt)
      slot.as(Int64*).value = v.value
    when Creme::CremeFfiShim::KIND_DOUBLE
      f = case v
          when SchemeFloat then v.value
          when SchemeInt   then v.value.to_f64
          else                  raise SchemeRuntimeError.new("#{who}: expected a real-number argument")
          end
      slot.as(Float64*).value = f
    when Creme::CremeFfiShim::KIND_BOOL
      raise SchemeRuntimeError.new("#{who}: expected a boolean argument") unless v.is_a?(SchemeBool)
      slot.as(Int32*).value = v.value? ? 1 : 0
    when Creme::CremeFfiShim::KIND_STRING
      if v.is_a?(SchemeBool) && !v.value?
        slot.as(Void**).value = Pointer(Void).null
      else
        raise SchemeRuntimeError.new("#{who}: expected a string (or #f) argument") unless v.is_a?(SchemeStr)
        slot.as(Void**).value = v.value.to_unsafe.as(Void*)
      end
    when Creme::CremeFfiShim::KIND_POINTER
      if v.is_a?(SchemeBool) && !v.value?
        slot.as(Void**).value = Pointer(Void).null
      else
        raise SchemeRuntimeError.new("#{who}: expected a pointer (or #f) argument") unless v.is_a?(SchemeBox) && v.tag == "ffi-pointer"
        slot.as(Void**).value = v.get(Pointer(Void))
      end
    else
      raise SchemeRuntimeError.new("#{who}: internal: bad type kind #{kind}")
    end
  end

  private def marshal_return(kind : Int32, slot : Void*) : SchemeValue
    case kind
    when Creme::CremeFfiShim::KIND_VOID   then NIL
    when Creme::CremeFfiShim::KIND_INT32  then SchemeInt.new(slot.as(Int32*).value.to_i64)
    when Creme::CremeFfiShim::KIND_INT64  then SchemeInt.new(slot.as(Int64*).value)
    when Creme::CremeFfiShim::KIND_DOUBLE then SchemeFloat.new(slot.as(Float64*).value)
    when Creme::CremeFfiShim::KIND_BOOL   then SchemeBool.of(slot.as(Int32*).value != 0)
    when Creme::CremeFfiShim::KIND_STRING
      ptr = slot.as(Void**).value
      ptr.null? ? FALSE : SchemeStr.new(String.new(ptr.as(UInt8*)))
    when Creme::CremeFfiShim::KIND_POINTER
      ptr = slot.as(Void**).value
      ptr.null? ? FALSE : SchemeBox.new("ffi-pointer", ptr, "#<ffi-pointer>")
    else
      raise SchemeRuntimeError.new("ffi-call: internal: bad return type kind #{kind}")
    end
  end
end

module Creme
  class Interpreter
    register_library ["creme", "builtin", "ffi"], Creme::Builtins::FfiLibrary
  end
end
