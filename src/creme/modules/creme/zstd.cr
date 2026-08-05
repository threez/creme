# ===========================================================================
# zstd module: Zstandard (facebook/zstd, BSD-3-Clause) compression
# ===========================================================================
#
# Binds libzstd directly (Crystal has no bundled zstd), the same raw-`lib`
# approach (creme cipher) uses for OpenSSL's EVP. Two layers:
#
#   * one-shot `zstd-compress`/`zstd-decompress` (bytevector<->bytevector) --
#     a frame with an embedded content size, decompressible by anyone.
#   * streaming, composable FILTER PORTS: `zstd-open-output-port` /
#     `zstd-open-input-port` wrap another port and transform incrementally, so
#     stacks like `compressed(encrypted(buffered(handle)))` work with bounded
#     memory. A SchemePort is a thin wrapper over a Crystal IO, so a filter port
#     is just an IO that forwards to the wrapped port's IO -- composition is IO
#     nesting. Closing cascades (the whole stack flushes + closes).
#
# Streaming frames (ZSTD_compressStream2) carry no content size, so they round-
# trip through `zstd-open-input-port` (and the `zstd` CLI) but NOT the one-shot
# `zstd-decompress`. The icecreme twin (icecreme/zstd.c + its general filter-port
# machinery) mirrors this exactly.
# ===========================================================================

@[Link("zstd")]
lib LibZstd
  # -- one-shot --
  fun compress_bound = ZSTD_compressBound(src_size : LibC::SizeT) : LibC::SizeT
  fun compress = ZSTD_compress(dst : UInt8*, dst_cap : LibC::SizeT, src : UInt8*, src_size : LibC::SizeT, level : Int32) : LibC::SizeT
  fun content_size = ZSTD_getFrameContentSize(src : UInt8*, src_size : LibC::SizeT) : UInt64
  fun decompress = ZSTD_decompress(dst : UInt8*, dst_cap : LibC::SizeT, src : UInt8*, src_size : LibC::SizeT) : LibC::SizeT
  fun is_error = ZSTD_isError(code : LibC::SizeT) : UInt32
  fun error_name = ZSTD_getErrorName(code : LibC::SizeT) : UInt8*

  # -- streaming --
  struct InBuffer
    src : UInt8*
    size : LibC::SizeT
    pos : LibC::SizeT
  end

  struct OutBuffer
    dst : UInt8*
    size : LibC::SizeT
    pos : LibC::SizeT
  end

  fun create_cctx = ZSTD_createCCtx : Void*
  fun free_cctx = ZSTD_freeCCtx(cctx : Void*) : LibC::SizeT
  fun cctx_set_parameter = ZSTD_CCtx_setParameter(cctx : Void*, param : Int32, value : Int32) : LibC::SizeT
  fun compress_stream2 = ZSTD_compressStream2(cctx : Void*, output : OutBuffer*, input : InBuffer*, end_op : Int32) : LibC::SizeT
  fun cstream_out_size = ZSTD_CStreamOutSize : LibC::SizeT

  fun create_dctx = ZSTD_createDCtx : Void*
  fun free_dctx = ZSTD_freeDCtx(dctx : Void*) : LibC::SizeT
  fun decompress_stream = ZSTD_decompressStream(dctx : Void*, output : OutBuffer*, input : InBuffer*) : LibC::SizeT
  fun dstream_in_size = ZSTD_DStreamInSize : LibC::SizeT
end

# zstd.h constants (stable ABI): the compression-level parameter id and the
# ZSTD_EndDirective values.
private ZSTD_C_COMPRESSION_LEVEL = 100
private ZSTD_E_CONTINUE          =   0
private ZSTD_E_FLUSH             =   1
private ZSTD_E_END               =   2

private def zstd_stream_error(code : LibC::SizeT, who : String) : Nil
  raise Creme::SchemeRuntimeError.new("#{who}: #{String.new(LibZstd.error_name(code))}") if LibZstd.is_error(code) != 0
end

# The backing IO for `zstd-open-output-port`: streams each write through a
# ZSTD_CCtx and forwards the produced bytes to the wrapped inner IO. close
# flushes the final frame block (ZSTD_e_end) and cascades close to the inner IO.
class Creme::Builtins::ZstdCompressIO < IO
  def initialize(@inner : IO, level : Int32)
    @cctx = LibZstd.create_cctx
    raise Creme::SchemeRuntimeError.new("zstd-open-output-port: failed to create compression context") if @cctx.null?
    LibZstd.cctx_set_parameter(@cctx, ZSTD_C_COMPRESSION_LEVEL, level)
    @out = Bytes.new(LibZstd.cstream_out_size.to_i)
    @closed = false
  end

  def read(slice : Bytes) : Int32
    raise IO::Error.new("zstd output port is not readable")
  end

  def write(slice : Bytes) : Nil
    drive(slice, ZSTD_E_CONTINUE)
  end

  def flush : Nil
    drive(Bytes.empty, ZSTD_E_FLUSH)
    @inner.flush
  end

  def close : Nil
    return if @closed
    @closed = true
    drive(Bytes.empty, ZSTD_E_END)
    @inner.close
    LibZstd.free_cctx(@cctx)
  end

  # Feeds `input` to the compressor with `end_op`, writing everything produced to
  # @inner. For ZSTD_e_continue the loop ends when the input is fully consumed;
  # for flush/end it ends when the compressor reports nothing left buffered (0).
  private def drive(input : Bytes, end_op : Int32) : Nil
    inp = LibZstd::InBuffer.new
    inp.src = input.to_unsafe
    inp.size = LibC::SizeT.new(input.size)
    inp.pos = LibC::SizeT.new(0)
    loop do
      outb = LibZstd::OutBuffer.new
      outb.dst = @out.to_unsafe
      outb.size = LibC::SizeT.new(@out.size)
      outb.pos = LibC::SizeT.new(0)
      remaining = LibZstd.compress_stream2(@cctx, pointerof(outb), pointerof(inp), end_op)
      zstd_stream_error(remaining, "zstd-compress")
      @inner.write(@out[0, outb.pos.to_i]) if outb.pos > 0
      if end_op == ZSTD_E_CONTINUE
        break if inp.pos >= inp.size
      else
        break if remaining == 0
      end
    end
  end
end

# The backing IO for `zstd-open-input-port`: pulls compressed bytes from the
# wrapped inner IO on demand and decompresses them incrementally.
class Creme::Builtins::ZstdDecompressIO < IO
  def initialize(@inner : IO)
    @dctx = LibZstd.create_dctx
    raise Creme::SchemeRuntimeError.new("zstd-open-input-port: failed to create decompression context") if @dctx.null?
    @in = Bytes.new(LibZstd.dstream_in_size.to_i)
    @in_len = 0
    @in_pos = 0
    @eof = false
    @closed = false
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("zstd input port is not writable")
  end

  def read(slice : Bytes) : Int32
    return 0 if slice.empty?
    loop do
      outb = LibZstd::OutBuffer.new
      outb.dst = slice.to_unsafe
      outb.size = LibC::SizeT.new(slice.size)
      outb.pos = LibC::SizeT.new(0)
      inp = LibZstd::InBuffer.new
      inp.src = @in.to_unsafe + @in_pos
      inp.size = LibC::SizeT.new(@in_len - @in_pos)
      inp.pos = LibC::SizeT.new(0)
      code = LibZstd.decompress_stream(@dctx, pointerof(outb), pointerof(inp))
      zstd_stream_error(code, "zstd-decompress")
      @in_pos += inp.pos.to_i
      return outb.pos.to_i if outb.pos > 0
      # Produced nothing: pull more compressed input, or stop at EOF.
      if @in_pos >= @in_len
        return 0 if @eof
        n = @inner.read(@in)
        if n <= 0
          @eof = true
          return 0
        end
        @in_len = n
        @in_pos = 0
      end
    end
  end

  def close : Nil
    return if @closed
    @closed = true
    @inner.close
    LibZstd.free_dctx(@dctx)
  end
end

module Creme::Builtins::ZstdLibrary
  extend self
  include Creme::BuiltinHelpers

  DEFAULT_LEVEL = 3

  # ZSTD_getFrameContentSize sentinels (zstd.h: (0ULL - 1) / (0ULL - 2)).
  CONTENTSIZE_UNKNOWN = UInt64::MAX
  CONTENTSIZE_ERROR   = UInt64::MAX - 1

  @[Creme::SchemeFn("zstd-compress", min: 1, max: 2)]
  def zstd_compress(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    src = zstd_bytes_arg(args[0], "zstd-compress")
    level = args.size > 1 ? zstd_level_arg(args[1], "zstd-compress") : DEFAULT_LEVEL
    SchemeBlob.new(compress_bytes(src, level, "zstd-compress"))
  end

  @[Creme::SchemeFn("zstd-decompress", min: 1, max: 1)]
  def zstd_decompress(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBlob.new(decompress_bytes(zstd_bytes_arg(args[0], "zstd-decompress"), "zstd-decompress"))
  end

  # A streaming, composable binary OUTPUT filter port: bytes written are
  # incrementally compressed and forwarded to `out` (another port). close-port
  # flushes the final frame block and cascades close to `out`.
  @[Creme::SchemeFn("zstd-open-output-port", min: 1, max: 2)]
  def zstd_open_output_port(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    inner = port_arg(args[0], "zstd-open-output-port")
    raise SchemeRuntimeError.new("zstd-open-output-port: expected an output port") unless inner.output?
    level = args.size > 1 ? zstd_level_arg(args[1], "zstd-open-output-port") : DEFAULT_LEVEL
    SchemePort.new(ZstdCompressIO.new(inner.io, level), false, true, binary: true)
  end

  # A streaming binary INPUT filter port: reads pull compressed bytes from `in`
  # on demand and decompress them incrementally.
  @[Creme::SchemeFn("zstd-open-input-port", min: 1, max: 1)]
  def zstd_open_input_port(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    inner = port_arg(args[0], "zstd-open-input-port")
    raise SchemeRuntimeError.new("zstd-open-input-port: expected an input port") unless inner.input?
    SchemePort.new(ZstdDecompressIO.new(inner.io), true, false, binary: true)
  end

  # --- one-shot codec core, shared by the one-shot builtins above ---

  def compress_bytes(src : Bytes, level : Int32, who : String) : Bytes
    bound = LibZstd.compress_bound(LibC::SizeT.new(src.size))
    dst = Bytes.new(bound.to_i)
    n = LibZstd.compress(dst.to_unsafe, bound, src.to_unsafe, LibC::SizeT.new(src.size), level)
    raise SchemeRuntimeError.new("#{who}: #{zstd_err(n)}") if LibZstd.is_error(n) != 0
    dst[0, n.to_i].dup
  end

  def decompress_bytes(src : Bytes, who : String) : Bytes
    size = LibZstd.content_size(src.to_unsafe, LibC::SizeT.new(src.size))
    case size
    when CONTENTSIZE_ERROR
      raise SchemeRuntimeError.new("#{who}: not a valid zstd frame")
    when CONTENTSIZE_UNKNOWN
      raise SchemeRuntimeError.new("#{who}: frame has no embedded content size")
    end
    dst = Bytes.new(size.to_i)
    n = LibZstd.decompress(dst.to_unsafe, LibC::SizeT.new(size), src.to_unsafe, LibC::SizeT.new(src.size))
    raise SchemeRuntimeError.new("#{who}: #{zstd_err(n)}") if LibZstd.is_error(n) != 0
    dst[0, n.to_i].dup
  end

  private def zstd_err(code : LibC::SizeT) : String
    String.new(LibZstd.error_name(code))
  end

  private def zstd_bytes_arg(v : SchemeValue, who : String) : Bytes
    case v
    when SchemeBlob then v.value
    when SchemeStr  then v.value.to_slice
    else
      raise SchemeRuntimeError.new("#{who}: expected a blob or string, got #{v.write_string}")
    end
  end

  private def zstd_level_arg(v : SchemeValue, who : String) : Int32
    raise SchemeRuntimeError.new("#{who}: expected an integer level, got #{v.write_string}") unless v.is_a?(SchemeInt)
    v.value.to_i32
  end
end

module Creme
  class Interpreter
    register_library ["creme", "builtin", "zstd"], Creme::Builtins::ZstdLibrary
  end
end
