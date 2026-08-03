/* (creme secure-random) — see secure_random.h. A port of
 * src/creme/modules/creme/secure_random.cr: secure-random-bytes/-hex/
 * -base64. Backed by OpenSSL's RAND_bytes (already linked via -lcrypto,
 * the exact same call icecreme/actor.c's own TCP/Unix handshake already uses
 * for its nonces) -- a genuine OS-entropy CSPRNG, deliberately separate
 * from (creme random)'s plain splitmix64 PRNG (builtins.c), the same way
 * native keeps Random::Secure apart from its own ordinary `Random`. hex/
 * base64 encoding here are small hand-rolled encode-only loops, matching
 * digest.c's own per-file self-contained style rather than sharing code
 * across builtin files. */
#include "builtin_config.h"

#if CREME_WITH_SECURE_RANDOM

#include <gc.h>
#include <openssl/rand.h>

#include "embed.h"
#include "secure_random.h"

static int secure_random_count_arg(Value *args, int nargs, const char *who) {
  int64_t n = creme_arg_int(args, nargs, 0, who);
  if (n < 0) creme_abort("%s: expected a non-negative integer", who);
  return (int)n;
}

static Value bi_secure_random_bytes(VM *vm, Value *args, int nargs) {
  (void)vm;
  int n = secure_random_count_arg(args, nargs, "secure-random-bytes");
  unsigned char *buf = GC_MALLOC((size_t)(n ? n : 1));
  if (n > 0 && !RAND_bytes(buf, n)) creme_abort("secure-random-bytes: RAND_bytes failed");
  Bytevector *bv = GC_MALLOC(sizeof(Bytevector));
  bv->bytes = buf;
  bv->len = n;
  return v_bytevector(bv);
}

static Value bi_secure_random_hex(VM *vm, Value *args, int nargs) {
  (void)vm;
  int n = secure_random_count_arg(args, nargs, "secure-random-hex");
  unsigned char *raw = GC_MALLOC((size_t)(n ? n : 1));
  if (n > 0 && !RAND_bytes(raw, n)) creme_abort("secure-random-hex: RAND_bytes failed");
  static const char hexchars[] = "0123456789abcdef";
  char *buf = GC_MALLOC((size_t)(n ? n * 2 : 1));
  for (int i = 0; i < n; i++) {
    buf[2 * i] = hexchars[raw[i] >> 4];
    buf[2 * i + 1] = hexchars[raw[i] & 0xf];
  }
  return v_str(buf, n * 2);
}

static const char B64_ALPHABET[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static Value bi_secure_random_base64(VM *vm, Value *args, int nargs) {
  (void)vm;
  int n = secure_random_count_arg(args, nargs, "secure-random-base64");
  unsigned char *in = GC_MALLOC((size_t)(n ? n : 1));
  if (n > 0 && !RAND_bytes(in, n)) creme_abort("secure-random-base64: RAND_bytes failed");

  int out_len = ((n + 2) / 3) * 4;
  char *out = GC_MALLOC((size_t)(out_len ? out_len : 1));
  int oi = 0, i = 0;
  for (; i + 3 <= n; i += 3) {
    unsigned int v = ((unsigned int)in[i] << 16) | ((unsigned int)in[i + 1] << 8) | (unsigned int)in[i + 2];
    out[oi++] = B64_ALPHABET[(v >> 18) & 0x3f];
    out[oi++] = B64_ALPHABET[(v >> 12) & 0x3f];
    out[oi++] = B64_ALPHABET[(v >> 6) & 0x3f];
    out[oi++] = B64_ALPHABET[v & 0x3f];
  }
  int rem = n - i;
  if (rem == 1) {
    unsigned int v = (unsigned int)in[i] << 16;
    out[oi++] = B64_ALPHABET[(v >> 18) & 0x3f];
    out[oi++] = B64_ALPHABET[(v >> 12) & 0x3f];
    out[oi++] = '=';
    out[oi++] = '=';
  } else if (rem == 2) {
    unsigned int v = ((unsigned int)in[i] << 16) | ((unsigned int)in[i + 1] << 8);
    out[oi++] = B64_ALPHABET[(v >> 18) & 0x3f];
    out[oi++] = B64_ALPHABET[(v >> 12) & 0x3f];
    out[oi++] = B64_ALPHABET[(v >> 6) & 0x3f];
    out[oi++] = '=';
  }
  return v_str(out, oi);
}

void creme_register_secure_random_builtins(VM *vm) {
  creme_register_builtin(vm, "secure-random-bytes", bi_secure_random_bytes);
  creme_register_builtin(vm, "secure-random-hex", bi_secure_random_hex);
  creme_register_builtin(vm, "secure-random-base64", bi_secure_random_base64);
}

#endif /* CREME_WITH_SECURE_RANDOM */
