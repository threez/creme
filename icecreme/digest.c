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
#include <gc.h>
#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <string.h>

#include "digest.h"

static void hex_encode_into(const unsigned char *bytes, unsigned int len, Value *out) {
  static const char hexchars[] = "0123456789abcdef";
  char *buf = GC_MALLOC((size_t)len * 2);
  for (unsigned int i = 0; i < len; i++) {
    buf[2 * i] = hexchars[bytes[i] >> 4];
    buf[2 * i + 1] = hexchars[bytes[i] & 0xf];
  }
  *out = v_str(buf, (int)len * 2);
}

static Value hex_digest(const EVP_MD *md, const char *data, int len) {
  unsigned char out[EVP_MAX_MD_SIZE];
  unsigned int outlen = 0;
  EVP_Digest(data, (size_t)len, out, &outlen, md, NULL);
  Value result;
  hex_encode_into(out, outlen, &result);
  return result;
}

static Value hmac_hex_digest(const EVP_MD *md, const char *key, int keylen, const char *data, int datalen) {
  unsigned char out[EVP_MAX_MD_SIZE];
  unsigned int outlen = 0;
  HMAC(md, key, keylen, (const unsigned char *)data, (size_t)datalen, out, &outlen);
  Value result;
  hex_encode_into(out, outlen, &result);
  return result;
}

/* Unlike the original three digest-*'s string-only contract (left
 * untouched below), every NEW procedure added in this file accepts
 * EITHER a bytevector or a string for its argument(s) -- a key is often
 * raw binary (e.g. straight from (creme secure-random)) -- matching
 * native's own digest_bytes_arg (src/creme/modules/creme/digest.cr). */
static void value_bytes(Value v, const char **out_ptr, int *out_len, const char *who) {
  if (v.tag == T_STR) {
    *out_ptr = v.as.chars;
    *out_len = v.aux;
    return;
  }
  if (v.tag == T_BYTEVECTOR) {
    *out_ptr = (const char *)v.as.bv->bytes;
    *out_len = v.as.bv->len;
    return;
  }
  creme_abort("%s: expected a blob or string argument", who);
}

static Value bi_digest_md5(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) creme_abort("digest-md5: expected string, got a non-string value");
  return hex_digest(EVP_md5(), args[0].as.chars, args[0].aux);
}

static Value bi_digest_sha1(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) creme_abort("digest-sha1: expected string, got a non-string value");
  return hex_digest(EVP_sha1(), args[0].as.chars, args[0].aux);
}

static Value bi_digest_sha256(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) creme_abort("digest-sha256: expected string, got a non-string value");
  return hex_digest(EVP_sha256(), args[0].as.chars, args[0].aux);
}

static Value bi_digest_sha384(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) creme_abort("digest-sha384: expected an argument");
  const char *ptr;
  int len;
  value_bytes(args[0], &ptr, &len, "digest-sha384");
  return hex_digest(EVP_sha384(), ptr, len);
}

static Value bi_digest_sha512(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) creme_abort("digest-sha512: expected an argument");
  const char *ptr;
  int len;
  value_bytes(args[0], &ptr, &len, "digest-sha512");
  return hex_digest(EVP_sha512(), ptr, len);
}

static Value bi_hmac_sha256(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2) creme_abort("hmac-sha256: expected 2 arguments");
  const char *kptr, *dptr;
  int klen, dlen;
  value_bytes(args[0], &kptr, &klen, "hmac-sha256");
  value_bytes(args[1], &dptr, &dlen, "hmac-sha256");
  return hmac_hex_digest(EVP_sha256(), kptr, klen, dptr, dlen);
}

static Value bi_hmac_sha384(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2) creme_abort("hmac-sha384: expected 2 arguments");
  const char *kptr, *dptr;
  int klen, dlen;
  value_bytes(args[0], &kptr, &klen, "hmac-sha384");
  value_bytes(args[1], &dptr, &dlen, "hmac-sha384");
  return hmac_hex_digest(EVP_sha384(), kptr, klen, dptr, dlen);
}

static Value bi_hmac_sha512(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2) creme_abort("hmac-sha512: expected 2 arguments");
  const char *kptr, *dptr;
  int klen, dlen;
  value_bytes(args[0], &kptr, &klen, "hmac-sha512");
  value_bytes(args[1], &dptr, &dlen, "hmac-sha512");
  return hmac_hex_digest(EVP_sha512(), kptr, klen, dptr, dlen);
}

static const char B64_ALPHABET[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static Value bi_base64_encode(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) creme_abort("base64-encode: expected string, got a non-string value");
  const unsigned char *in = (const unsigned char *)args[0].as.chars;
  int len = args[0].aux;
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
  if (nargs < 1 || args[0].tag != T_STR) creme_abort("base64-decode: expected string, got a non-string value");
  const char *s = args[0].as.chars;
  int len = args[0].aux;
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
