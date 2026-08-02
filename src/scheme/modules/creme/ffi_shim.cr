# ===========================================================================
# LibCremeFfi: bindings to ffi_shim.c/.o, a small precompiled dlopen/libffi
# bridge (see that file's own header comment for why a shim exists at all
# instead of declaring libffi's own structs directly in Crystal).
# ===========================================================================
#
# ffi.cr is the only caller — this file is pure plumbing, no Scheme-facing
# surface of its own.

@[Link("ffi")]
@[Link("dl")]
@[Link(ldflags: "#{__DIR__}/ffi_shim.o")]
lib LibCremeFfi
  fun creme_ffi_dlopen(path : UInt8*) : Void*
  fun creme_ffi_last_error : UInt8*
  fun creme_ffi_dlclose(handle : Void*) : Void
  fun creme_ffi_prepare(handle : Void*, name : UInt8*, ret_kind : Int32, arg_kinds : Int32*, n_args : Int32) : Void*
  fun creme_ffi_invoke(prepared : Void*, arg_values : Void**, ret_value : Void*) : Void
  fun creme_ffi_release(prepared : Void*) : Void
end

module Scheme
  module CremeFfiShim
    # Must match ffi_shim.c's own creme_ffi_type_for_kind switch AND
    # ffi.cr's Kind-parsing exactly — three independent copies of the same
    # small enum (the other two: ffi_shim.c here, cvm/creme_ffi.c on the
    # cvm side) rather than a shared header, since Crystal/C/cvm's C each
    # need their own literal copy regardless.
    KIND_VOID    = 0
    KIND_INT32   = 1
    KIND_INT64   = 2
    KIND_DOUBLE  = 3
    KIND_BOOL    = 4
    KIND_STRING  = 5
    KIND_POINTER = 6

    def self.dlopen(path : String) : Void*
      handle = LibCremeFfi.creme_ffi_dlopen(path)
      raise SchemeRuntimeError.new("ffi-open: #{path}: #{last_error}") if handle.null?
      handle
    end

    def self.dlclose(handle : Void*) : Nil
      LibCremeFfi.creme_ffi_dlclose(handle)
    end

    def self.prepare(handle : Void*, name : String, ret_kind : Int32, arg_kinds : Array(Int32)) : Void*
      kinds = arg_kinds.to_unsafe
      prepared = LibCremeFfi.creme_ffi_prepare(handle, name, ret_kind, kinds, arg_kinds.size)
      raise SchemeRuntimeError.new("ffi-function: #{name}: #{last_error}") if prepared.null?
      prepared
    end

    # `arg_values`/`ret_value`: one 8-byte slot per prepared argument (large
    # enough for every MVP scalar kind), plus one more for the return value
    # — ffi.cr builds these from the Scheme argument list and reads the
    # return slot back out afterward.
    def self.invoke(prepared : Void*, arg_values : Void**, ret_value : Void*) : Nil
      LibCremeFfi.creme_ffi_invoke(prepared, arg_values, ret_value)
    end

    def self.release(prepared : Void*) : Nil
      LibCremeFfi.creme_ffi_release(prepared)
    end

    private def self.last_error : String
      msg = LibCremeFfi.creme_ffi_last_error
      msg.null? ? "unknown error" : String.new(msg)
    end
  end
end
