/* (creme digest) — see digest.h. A port of
 * src/creme/modules/creme/digest.cr: digest-md5/digest-sha1/digest-
 * sha256/digest-sha384/digest-sha512 (hex digest strings), hmac-sha256/
 * hmac-sha384/hmac-sha512, plus base64-encode/decode. Crystal's own
 * `require "digest/md5"`/`sha1`/`sha256`/`sha512`/`openssl/digest`/
 * `openssl/hmac`/`base64` are all STANDARD LIBRARY, not external shards
 * (see shard.yml) -- backed here by OpenSSL's EVP_Digest/HMAC (already
 * linked via -lcrypto, from (creme actor)'s own HMAC-SHA256 handshake)
 * plus a small hand-rolled base64 codec (OpenSSL's own
 * EVP_EncodeBlock/DecodeBlock have padding/whitespace-tolerance quirks
 * that make matching Crystal's own Base64.strict_encode/decode_string
 * behavior -- including raising a clear error on invalid input -- more
 * awkward than just writing the ~40 lines directly). */
#include "builtin_config.h"

#if CREME_WITH_DIGEST

#include <gc.h>
#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <string.h>

#include "digest.h"
#include "embed.h"

static Value hex_digest(const EVP_MD *md, const char *data, int len) {
  unsigned char out[EVP_MAX_MD_SIZE];
  unsigned int outlen = 0;
  if (EVP_Digest(data, (size_t)len, out, &outlen, md, NULL) != 1)
    creme_abort("digest: hashing failed");
  return creme_hex_value(out, (int)outlen);
}

static Value hmac_hex_digest(const EVP_MD *md, const char *key, int keylen, const char *data, int datalen) {
  unsigned char out[EVP_MAX_MD_SIZE];
  unsigned int outlen = 0;
  if (HMAC(md, key, keylen, (const unsigned char *)data, (size_t)datalen, out, &outlen) == NULL)
    creme_abort("hmac: computation failed");
  return creme_hex_value(out, (int)outlen);
}

static Value bi_digest_md5(VM *vm, Value *args, int nargs) {
  (void)vm;
  int len;
  const char *data = creme_arg_bytes(args, nargs, 0, "digest-md5", &len);
  return hex_digest(EVP_md5(), data, len);
}

static Value bi_digest_sha1(VM *vm, Value *args, int nargs) {
  (void)vm;
  int len;
  const char *data = creme_arg_bytes(args, nargs, 0, "digest-sha1", &len);
  return hex_digest(EVP_sha1(), data, len);
}

static Value bi_digest_sha256(VM *vm, Value *args, int nargs) {
  (void)vm;
  int len;
  const char *data = creme_arg_bytes(args, nargs, 0, "digest-sha256", &len);
  return hex_digest(EVP_sha256(), data, len);
}

/* Unlike the original three digest-*'s string-only contract above, every
 * procedure below accepts EITHER a bytevector or a string for its
 * argument(s) -- a key is often raw binary (e.g. straight from (creme
 * secure-random)) -- matching native's own digest_bytes_arg
 * (src/creme/modules/creme/digest.cr); creme_arg_blob (embed.h) is the
 * shared helper for that string-or-bytevector union. */
static Value bi_digest_sha384(VM *vm, Value *args, int nargs) {
  (void)vm;
  int len;
  const char *ptr = (const char *)creme_arg_blob(args, nargs, 0, "digest-sha384", &len);
  return hex_digest(EVP_sha384(), ptr, len);
}

static Value bi_digest_sha512(VM *vm, Value *args, int nargs) {
  (void)vm;
  int len;
  const char *ptr = (const char *)creme_arg_blob(args, nargs, 0, "digest-sha512", &len);
  return hex_digest(EVP_sha512(), ptr, len);
}

static Value bi_hmac_sha256(VM *vm, Value *args, int nargs) {
  (void)vm;
  int klen, dlen;
  const char *kptr = (const char *)creme_arg_blob(args, nargs, 0, "hmac-sha256", &klen);
  const char *dptr = (const char *)creme_arg_blob(args, nargs, 1, "hmac-sha256", &dlen);
  return hmac_hex_digest(EVP_sha256(), kptr, klen, dptr, dlen);
}

static Value bi_hmac_sha384(VM *vm, Value *args, int nargs) {
  (void)vm;
  int klen, dlen;
  const char *kptr = (const char *)creme_arg_blob(args, nargs, 0, "hmac-sha384", &klen);
  const char *dptr = (const char *)creme_arg_blob(args, nargs, 1, "hmac-sha384", &dlen);
  return hmac_hex_digest(EVP_sha384(), kptr, klen, dptr, dlen);
}

static Value bi_hmac_sha512(VM *vm, Value *args, int nargs) {
  (void)vm;
  int klen, dlen;
  const char *kptr = (const char *)creme_arg_blob(args, nargs, 0, "hmac-sha512", &klen);
  const char *dptr = (const char *)creme_arg_blob(args, nargs, 1, "hmac-sha512", &dlen);
  return hmac_hex_digest(EVP_sha512(), kptr, klen, dptr, dlen);
}

static const char B64_ALPHABET[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static Value bi_base64_encode(VM *vm, Value *args, int nargs) {
  (void)vm;
  int len;
  const unsigned char *in = (const unsigned char *)creme_arg_bytes(args, nargs, 0, "base64-encode", &len);
  int out_len = ((len + 2) / 3) * 4;
  char *out = GC_MALLOC((size_t)(out_len ? out_len : 1));
  int oi = 0, i = 0;
  for (; i + 3 <= len; i += 3) {
    unsigned int n = ((unsigned int)in[i] << 16) | ((unsigned int)in[i + 1] << 8) | (unsigned int)in[i + 2];
    out[oi++] = B64_ALPHABET[(n >> 18) & 0x3f];
    out[oi++] = B64_ALPHABET[(n >> 12) & 0x3f];
    out[oi++] = B64_ALPHABET[(n >> 6) & 0x3f];
    out[oi++] = B64_ALPHABET[n & 0x3f];
  }
  int rem = len - i;
  if (rem == 1) {
    unsigned int n = (unsigned int)in[i] << 16;
    out[oi++] = B64_ALPHABET[(n >> 18) & 0x3f];
    out[oi++] = B64_ALPHABET[(n >> 12) & 0x3f];
    out[oi++] = '=';
    out[oi++] = '=';
  } else if (rem == 2) {
    unsigned int n = ((unsigned int)in[i] << 16) | ((unsigned int)in[i + 1] << 8);
    out[oi++] = B64_ALPHABET[(n >> 18) & 0x3f];
    out[oi++] = B64_ALPHABET[(n >> 12) & 0x3f];
    out[oi++] = B64_ALPHABET[(n >> 6) & 0x3f];
    out[oi++] = '=';
  }
  return v_str(out, oi);
}

static int b64_value(char c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '+') return 62;
  if (c == '/') return 63;
  return -1;
}

static Value bi_base64_decode(VM *vm, Value *args, int nargs) {
  (void)vm;
  int len;
  const char *s = creme_arg_bytes(args, nargs, 0, "base64-decode", &len);
  if (len == 0) return v_str(GC_MALLOC(1), 0);
  if (len % 4 != 0) creme_abort("base64-decode: invalid base64: input length must be a multiple of 4");

  /* '=' padding may only appear as (up to) the last two characters. */
  for (int i = 0; i < len - 2; i++) {
    if (s[i] == '=') creme_abort("base64-decode: invalid base64: unexpected '=' padding");
  }
  int pad = 0;
  if (s[len - 1] == '=') pad++;
  if (pad == 1 && s[len - 2] == '=') pad++;
  if (pad == 0 && s[len - 2] == '=') creme_abort("base64-decode: invalid base64: unexpected '=' padding");

  int out_len = (len / 4) * 3 - pad;
  char *out = GC_MALLOC((size_t)(out_len ? out_len : 1));
  int oi = 0;
  for (int i = 0; i < len; i += 4) {
    int gp = (i + 4 == len) ? pad : 0;
    int v0 = b64_value(s[i]);
    int v1 = b64_value(s[i + 1]);
    int v2 = (gp >= 2) ? 0 : b64_value(s[i + 2]);
    int v3 = (gp >= 1) ? 0 : b64_value(s[i + 3]);
    if (v0 < 0 || v1 < 0 || (gp < 2 && v2 < 0) || (gp < 1 && v3 < 0)) {
      creme_abort("base64-decode: invalid base64: contains a character outside the base64 alphabet");
    }
    unsigned int n = ((unsigned int)v0 << 18) | ((unsigned int)v1 << 12) | ((unsigned int)v2 << 6) | (unsigned int)v3;
    out[oi++] = (char)((n >> 16) & 0xff);
    if (gp < 2) out[oi++] = (char)((n >> 8) & 0xff);
    if (gp < 1) out[oi++] = (char)(n & 0xff);
  }
  return v_str(out, oi);
}

void creme_register_digest_builtins(VM *vm) {
  creme_register_builtin(vm, "digest-md5", bi_digest_md5);
  creme_register_builtin(vm, "digest-sha1", bi_digest_sha1);
  creme_register_builtin(vm, "digest-sha256", bi_digest_sha256);
  creme_register_builtin(vm, "digest-sha384", bi_digest_sha384);
  creme_register_builtin(vm, "digest-sha512", bi_digest_sha512);
  creme_register_builtin(vm, "hmac-sha256", bi_hmac_sha256);
  creme_register_builtin(vm, "hmac-sha384", bi_hmac_sha384);
  creme_register_builtin(vm, "hmac-sha512", bi_hmac_sha512);
  creme_register_builtin(vm, "base64-encode", bi_base64_encode);
  creme_register_builtin(vm, "base64-decode", bi_base64_decode);
}

#endif /* CREME_WITH_DIGEST */
