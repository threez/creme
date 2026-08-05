/* (creme zstd) -- zstd-compress/zstd-decompress, backed by libzstd
 * (facebook/zstd, BSD-3-Clause). The byte-identical twin of native's own
 * (creme zstd) (src/creme/modules/creme/zstd.cr, which binds the same libzstd
 * one-shot API via Crystal FFI).
 *
 * Two layers, mirroring native's zstd.cr:
 *   - one-shot zstd-compress/zstd-decompress (below): a frame with an embedded
 *     content size, so zstd-decompress sizes its output exactly via
 *     ZSTD_getFrameContentSize (a streamed frame lacking that size is rejected).
 *   - streaming, composable FILTER ports (zstd-open-output-port/-input-port):
 *     built on icecreme's general PORT_KIND_FILTER machinery (value.h FilterOps +
 *     builtins.c dispatch), so filters stack into pipelines. These use the
 *     ZSTD_compressStream2/decompressStream API; their frames have no content
 *     size and round-trip via zstd-open-input-port (and the zstd CLI), not the
 *     one-shot zstd-decompress. Buffers are GC_MALLOC'd like everything here. */
/* zstd is a REQUIRED core dependency (not an optional CREME_WITH_* family): the
 * ICE bytecode container is zstd-compressed, so loader.c decompresses every
 * chunk and the self-hosted compiler (bytecode.sld) compresses on emit. So this
 * file is always compiled and libzstd always linked -- there is no gate. */
#include <gc.h>
#include <limits.h>
#include <zstd.h>

#include "embed.h"
#include "zstd.h"

static Value bi_zstd_compress(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "zstd-compress");
  int len;
  const unsigned char *src = creme_arg_blob(args, nargs, 0, "zstd-compress", &len);
  int level = nargs >= 2 ? (int)creme_arg_int(args, nargs, 1, "zstd-compress") : 3;
  size_t bound = ZSTD_compressBound((size_t)len);
  unsigned char *dst = GC_MALLOC(bound);
  size_t n = ZSTD_compress(dst, bound, src, (size_t)len, level);
  if (ZSTD_isError(n)) creme_abort("zstd-compress: %s", ZSTD_getErrorName(n));
  /* dst was over-allocated to the worst-case bound; copy out the exact n. */
  return creme_bytevector_value(dst, (int)n);
}

static Value bi_zstd_decompress(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "zstd-decompress");
  int len;
  const unsigned char *src = creme_arg_blob(args, nargs, 0, "zstd-decompress", &len);
  unsigned long long sz = ZSTD_getFrameContentSize(src, (size_t)len);
  if (sz == ZSTD_CONTENTSIZE_ERROR) creme_abort("zstd-decompress: not a valid zstd frame");
  if (sz == ZSTD_CONTENTSIZE_UNKNOWN) creme_abort("zstd-decompress: frame has no embedded content size");
  if (sz > (unsigned long long)INT_MAX) creme_abort("zstd-decompress: decompressed size too large");
  unsigned char *dst = GC_MALLOC(sz ? (size_t)sz : 1);
  size_t n = ZSTD_decompress(dst, (size_t)sz, src, (size_t)len);
  if (ZSTD_isError(n)) creme_abort("zstd-decompress: %s", ZSTD_getErrorName(n));
  return creme_bytevector_wrap(dst, (int)n);
}

static int zstd_port_is_output(Port *p) {
  return p->kind == PORT_KIND_STDOUT || p->kind == PORT_KIND_OUTPUT_FILE || p->kind == PORT_KIND_OUTPUT_STRING ||
         (p->kind == PORT_KIND_FILTER && !p->filter_input);
}

static int zstd_port_is_input(Port *p) {
  return p->kind == PORT_KIND_STDIN || p->kind == PORT_KIND_INPUT_FILE || p->kind == PORT_KIND_INPUT_STRING ||
         (p->kind == PORT_KIND_FILTER && p->filter_input);
}

/* ---- streaming filter state + FilterOps (see icecreme/value.h) ------------
 * These are the concrete zstd instances of the general filter-port vtable. An
 * output (compress) filter streams each write through a ZSTD_CCtx, forwarding
 * produced bytes to self->wrapped; an input (decompress) filter refills the
 * port's own buf/len/pos by ZSTD_decompressStream-ing bytes pulled from
 * self->wrapped. Streamed frames carry no content size, so they round-trip via
 * zstd-open-input-port (and the zstd CLI) but not the one-shot zstd-decompress.
 * The ZSTD_CCtx/ZSTD_DCtx use libzstd's own allocator and are freed in on_close. */

typedef struct {
  ZSTD_CCtx *cctx;
  unsigned char *out; /* staging for produced compressed bytes */
  size_t out_cap;
} ZstdCompressState;

typedef struct {
  ZSTD_DCtx *dctx;
  unsigned char *in; /* staging for compressed bytes pulled from `wrapped` */
  size_t in_cap, in_len, in_pos;
  int eof;
} ZstdDecompressState;

static void zstd_compress_drive(Port *self, const unsigned char *in, int len, ZSTD_EndDirective op) {
  ZstdCompressState *st = self->filter_state;
  ZSTD_inBuffer input = {in, (size_t)len, 0};
  for (;;) {
    ZSTD_outBuffer output = {st->out, st->out_cap, 0};
    size_t remaining = ZSTD_compressStream2(st->cctx, &output, &input, op);
    if (ZSTD_isError(remaining)) creme_abort("zstd-compress: %s", ZSTD_getErrorName(remaining));
    if (output.pos > 0) creme_port_write_bytes(self->wrapped, (const char *)st->out, (int)output.pos);
    if (op == ZSTD_e_continue) {
      if (input.pos >= input.size) break;
    } else if (remaining == 0) {
      break;
    }
  }
}

static void zstd_compress_on_write(Port *self, const unsigned char *in, int len) { zstd_compress_drive(self, in, len, ZSTD_e_continue); }
static void zstd_compress_on_flush(Port *self) { zstd_compress_drive(self, NULL, 0, ZSTD_e_flush); }
static void zstd_compress_on_close(Port *self) {
  zstd_compress_drive(self, NULL, 0, ZSTD_e_end);
  ZSTD_freeCCtx(((ZstdCompressState *)self->filter_state)->cctx);
}

/* Pull up to `cap` compressed bytes from `wrapped` (char-by-char through the
 * shared port read helper, so `wrapped` can itself be any port -- incl another
 * filter, which is how stacks compose). */
static int zstd_pull(Port *wrapped, unsigned char *buf, int cap) {
  int n = 0, c;
  while (n < cap && (c = creme_port_read_char(wrapped)) >= 0) buf[n++] = (unsigned char)c;
  return n;
}

static int zstd_decompress_refill(Port *self) {
  ZstdDecompressState *st = self->filter_state;
  for (;;) {
    ZSTD_outBuffer output = {(void *)self->buf, (size_t)self->cap, 0};
    ZSTD_inBuffer input = {st->in + st->in_pos, st->in_len - st->in_pos, 0};
    size_t code = ZSTD_decompressStream(st->dctx, &output, &input);
    if (ZSTD_isError(code)) creme_abort("zstd-decompress: %s", ZSTD_getErrorName(code));
    st->in_pos += input.pos;
    if (output.pos > 0) {
      self->pos = 0;
      self->len = (int)output.pos;
      return 1;
    }
    /* produced nothing: need more compressed input, or we're done */
    if (st->in_pos >= st->in_len) {
      if (st->eof) return 0;
      int n = zstd_pull(self->wrapped, st->in, (int)st->in_cap);
      if (n <= 0) {
        st->eof = 1; /* loop once more with empty input to drain any buffered output */
      } else {
        st->in_len = (size_t)n;
        st->in_pos = 0;
      }
    }
  }
}

static void zstd_decompress_on_close(Port *self) { ZSTD_freeDCtx(((ZstdDecompressState *)self->filter_state)->dctx); }

static const FilterOps ZSTD_COMPRESS_OPS = {zstd_compress_on_write, zstd_compress_on_flush, zstd_compress_on_close, NULL};
static const FilterOps ZSTD_DECOMPRESS_OPS = {NULL, NULL, zstd_decompress_on_close, zstd_decompress_refill};

/* (zstd-open-output-port out [level]) -- a streaming binary output filter port:
 * each write is incrementally compressed and forwarded to `out`; close-port
 * flushes the final frame block and cascades close to `out`. */
static Value bi_zstd_open_output_port(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "zstd-open-output-port");
  Port *inner = creme_arg_port(args, nargs, 0, "zstd-open-output-port");
  if (!zstd_port_is_output(inner)) creme_abort("zstd-open-output-port: expected an output port");
  int level = nargs >= 2 ? (int)creme_arg_int(args, nargs, 1, "zstd-open-output-port") : 3;
  ZstdCompressState *st = GC_MALLOC(sizeof(ZstdCompressState));
  st->cctx = ZSTD_createCCtx();
  if (!st->cctx) creme_abort("zstd-open-output-port: failed to create compression context");
  ZSTD_CCtx_setParameter(st->cctx, ZSTD_c_compressionLevel, level);
  st->out_cap = ZSTD_CStreamOutSize();
  st->out = GC_MALLOC(st->out_cap);
  Port *p = GC_MALLOC(sizeof(Port));
  p->kind = PORT_KIND_FILTER;
  p->binary = 1;
  p->filter = &ZSTD_COMPRESS_OPS;
  p->filter_state = st;
  p->wrapped = inner;
  p->filter_input = 0;
  return v_port(p);
}

/* (zstd-open-input-port in) -- a streaming binary input filter port: reads pull
 * compressed bytes from `in` on demand and decompress them incrementally. */
static Value bi_zstd_open_input_port(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "zstd-open-input-port");
  Port *inner = creme_arg_port(args, nargs, 0, "zstd-open-input-port");
  if (!zstd_port_is_input(inner)) creme_abort("zstd-open-input-port: expected an input port");
  ZstdDecompressState *st = GC_MALLOC(sizeof(ZstdDecompressState));
  st->dctx = ZSTD_createDCtx();
  if (!st->dctx) creme_abort("zstd-open-input-port: failed to create decompression context");
  st->in_cap = ZSTD_DStreamInSize();
  st->in = GC_MALLOC(st->in_cap);
  st->in_len = st->in_pos = 0;
  st->eof = 0;
  Port *p = GC_MALLOC(sizeof(Port));
  p->kind = PORT_KIND_FILTER;
  p->binary = 1;
  p->filter = &ZSTD_DECOMPRESS_OPS;
  p->filter_state = st;
  p->wrapped = inner;
  p->filter_input = 1;
  p->cap = (int)ZSTD_DStreamOutSize(); /* decoded-output buffer the refill fills */
  p->buf = GC_MALLOC((size_t)p->cap);
  return v_port(p);
}

void creme_register_zstd_builtins(VM *vm) {
  creme_register_builtin(vm, "zstd-compress", bi_zstd_compress);
  creme_register_builtin(vm, "zstd-decompress", bi_zstd_decompress);
  creme_register_builtin(vm, "zstd-open-output-port", bi_zstd_open_output_port);
  creme_register_builtin(vm, "zstd-open-input-port", bi_zstd_open_input_port);
}
