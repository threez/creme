/* (creme cipher) — see cipher.h. A port of
 * src/creme/modules/creme/cipher.cr: aes-256-gcm-encrypt/-decrypt/
 * -random-key/-random-nonce. Deliberately scoped to ONE algorithm/mode
 * (AES-256-GCM, authenticated encryption, the modern default) rather
 * than Ruby's much broader OpenSSL::Cipher cipher-name-string surface --
 * no raw CBC/ECB offered here, matching (creme rfc8439)'s own AEAD-first
 * cut for ChaCha20-Poly1305. Unlike native's own cipher.cr (which has to
 * reopen Crystal's OpenSSL::LibCrypto binding to add EVP_CIPHER_CTX_ctrl,
 * since that Crystal version's own OpenSSL::Cipher wrapper has no GCM/
 * AEAD support at all), icecreme drives OpenSSL's C API directly, where the
 * full EVP AEAD surface (EVP_CIPHER_CTX_ctrl, EVP_aes_256_gcm,
 * EVP_CTRL_GCM_SET_IVLEN/GET_TAG/SET_TAG) is simply part of
 * <openssl/evp.h> -- already linked via -lcrypto, the same link (creme
 * digest)'s EVP_Digest/HMAC and (creme actor)'s own HMAC-SHA256
 * handshake already use.
 *
 * cvm_abort longjmps out of the current builtin call on any error path
 * (see vm.c's own cvm_abort, used from a live (guard ...) handler) --
 * every error branch below explicitly EVP_CIPHER_CTX_free()s first, so
 * a repeated failure (e.g. a bad tag on every retry) can't leak an
 * EVP_CIPHER_CTX each time the way an unwinding C++ exception would
 * avoid via RAII but plain C longjmp does not. */
#include <gc.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <string.h>

#include "cipher.h"

#define CIPHER_KEY_SIZE 32   /* AES-256 */
#define CIPHER_NONCE_SIZE 12 /* GCM's standard 96-bit nonce */
#define CIPHER_TAG_SIZE 16

static void value_bytes(Value v, const unsigned char **out_ptr, int *out_len, const char *who) {
  if (v.tag == T_STR) {
    *out_ptr = (const unsigned char *)v.as.chars;
    *out_len = v.aux;
    return;
  }
  if (v.tag == T_BYTEVECTOR) {
    *out_ptr = v.as.bv->bytes;
    *out_len = v.as.bv->len;
    return;
  }
  cvm_abort("%s: expected a blob or string argument", who);
}

static Value str_lit(const char *s) { return v_str(s, (int)strlen(s)); }

static Value cons2(Value car, Value cdr) {
  Pair *p = GC_MALLOC(sizeof(Pair));
  p->car = car;
  p->cdr = cdr;
  return v_pair(p);
}

static Value alist_pair(const char *key, Value val) { return cons2(str_lit(key), val); }

static Value bytevector_value(const unsigned char *bytes, int len) {
  Bytevector *bv = GC_MALLOC(sizeof(Bytevector));
  bv->bytes = (unsigned char *)bytes;
  bv->len = len;
  return v_bytevector(bv);
}

static Value random_bytevector(int n, const char *who) {
  unsigned char *buf = GC_MALLOC((size_t)n);
  if (!RAND_bytes(buf, n)) cvm_abort("%s: RAND_bytes failed", who);
  return bytevector_value(buf, n);
}

static Value bi_aes_256_gcm_random_key(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)args;
  (void)nargs;
  return random_bytevector(CIPHER_KEY_SIZE, "aes-256-gcm-random-key");
}

static Value bi_aes_256_gcm_random_nonce(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)args;
  (void)nargs;
  return random_bytevector(CIPHER_NONCE_SIZE, "aes-256-gcm-random-nonce");
}

/* A too-short key/nonce here would make EVP_CipherInit_ex read PAST the
 * end of the given buffer (it trusts the cipher's own declared key/iv
 * length, not whatever size the caller's buffer actually is) -- this
 * check is a memory-safety gate, not just an API-correctness one, and
 * must run before any FFI call touches key/nonce. */
static EVP_CIPHER_CTX *cipher_new_ctx(const unsigned char *key, int keylen, const unsigned char *nonce, int noncelen, int enc,
                                       const char *who) {
  if (keylen != CIPHER_KEY_SIZE) cvm_abort("%s: expected a %d-byte key, got %d bytes", who, CIPHER_KEY_SIZE, keylen);
  if (noncelen != CIPHER_NONCE_SIZE) cvm_abort("%s: expected a %d-byte nonce, got %d bytes", who, CIPHER_NONCE_SIZE, noncelen);

  EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
  if (!ctx) cvm_abort("%s: failed to allocate a cipher context", who);
  if (EVP_CipherInit_ex(ctx, EVP_aes_256_gcm(), NULL, NULL, NULL, enc) != 1) {
    EVP_CIPHER_CTX_free(ctx);
    cvm_abort("%s: EVP_CipherInit_ex failed", who);
  }
  if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, noncelen, NULL) != 1) {
    EVP_CIPHER_CTX_free(ctx);
    cvm_abort("%s: failed to set the GCM nonce length", who);
  }
  if (EVP_CipherInit_ex(ctx, NULL, NULL, key, nonce, enc) != 1) {
    EVP_CIPHER_CTX_free(ctx);
    cvm_abort("%s: EVP_CipherInit_ex (key/nonce) failed", who);
  }
  return ctx;
}

static void cipher_feed_aad(EVP_CIPHER_CTX *ctx, const unsigned char *aad, int aadlen, const char *who) {
  if (aadlen <= 0) return;
  int outlen = 0;
  if (EVP_CipherUpdate(ctx, NULL, &outlen, aad, aadlen) != 1) {
    EVP_CIPHER_CTX_free(ctx);
    cvm_abort("%s: failed to authenticate additional data", who);
  }
}

static Value bi_aes_256_gcm_encrypt(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 3) cvm_abort("aes-256-gcm-encrypt: expected at least 3 arguments");
  const unsigned char *key, *nonce, *pt, *aad = NULL;
  int keylen, noncelen, ptlen, aadlen = 0;
  value_bytes(args[0], &key, &keylen, "aes-256-gcm-encrypt");
  value_bytes(args[1], &nonce, &noncelen, "aes-256-gcm-encrypt");
  value_bytes(args[2], &pt, &ptlen, "aes-256-gcm-encrypt");
  if (nargs >= 4) value_bytes(args[3], &aad, &aadlen, "aes-256-gcm-encrypt");

  EVP_CIPHER_CTX *ctx = cipher_new_ctx(key, keylen, nonce, noncelen, 1, "aes-256-gcm-encrypt");
  cipher_feed_aad(ctx, aad, aadlen, "aes-256-gcm-encrypt");

  unsigned char *outbuf = GC_MALLOC((size_t)ptlen + CIPHER_TAG_SIZE);
  int outlen = 0;
  if (EVP_CipherUpdate(ctx, outbuf, &outlen, pt, ptlen) != 1) {
    EVP_CIPHER_CTX_free(ctx);
    cvm_abort("aes-256-gcm-encrypt: EVP_CipherUpdate failed");
  }
  int total = outlen;
  int finlen = 0;
  if (EVP_CipherFinal_ex(ctx, outbuf + total, &finlen) != 1) {
    EVP_CIPHER_CTX_free(ctx);
    cvm_abort("aes-256-gcm-encrypt: EVP_CipherFinal_ex failed");
  }
  total += finlen;

  unsigned char *tag = GC_MALLOC(CIPHER_TAG_SIZE);
  if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, CIPHER_TAG_SIZE, tag) != 1) {
    EVP_CIPHER_CTX_free(ctx);
    cvm_abort("aes-256-gcm-encrypt: failed to get the authentication tag");
  }
  EVP_CIPHER_CTX_free(ctx);

  return cons2(alist_pair("ciphertext", bytevector_value(outbuf, total)),
               cons2(alist_pair("tag", bytevector_value(tag, CIPHER_TAG_SIZE)), v_nil()));
}

static Value bi_aes_256_gcm_decrypt(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 4) cvm_abort("aes-256-gcm-decrypt: expected at least 4 arguments");
  const unsigned char *key, *nonce, *ct, *tag, *aad = NULL;
  int keylen, noncelen, ctlen, taglen, aadlen = 0;
  value_bytes(args[0], &key, &keylen, "aes-256-gcm-decrypt");
  value_bytes(args[1], &nonce, &noncelen, "aes-256-gcm-decrypt");
  value_bytes(args[2], &ct, &ctlen, "aes-256-gcm-decrypt");
  value_bytes(args[3], &tag, &taglen, "aes-256-gcm-decrypt");
  if (nargs >= 5) value_bytes(args[4], &aad, &aadlen, "aes-256-gcm-decrypt");
  if (taglen != CIPHER_TAG_SIZE) cvm_abort("aes-256-gcm-decrypt: expected a %d-byte tag, got %d bytes", CIPHER_TAG_SIZE, taglen);

  EVP_CIPHER_CTX *ctx = cipher_new_ctx(key, keylen, nonce, noncelen, 0, "aes-256-gcm-decrypt");
  cipher_feed_aad(ctx, aad, aadlen, "aes-256-gcm-decrypt");

  unsigned char *outbuf = GC_MALLOC((size_t)ctlen + CIPHER_TAG_SIZE);
  int outlen = 0;
  if (EVP_CipherUpdate(ctx, outbuf, &outlen, ct, ctlen) != 1) {
    EVP_CIPHER_CTX_free(ctx);
    cvm_abort("aes-256-gcm-decrypt: EVP_CipherUpdate failed");
  }
  int total = outlen;
  /* EVP_CTRL_GCM_ takes a non-const void* even though it never writes
   * through it for SET_TAG -- `tag` is otherwise treated read-only. */
  if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, CIPHER_TAG_SIZE, (void *)tag) != 1) {
    EVP_CIPHER_CTX_free(ctx);
    cvm_abort("aes-256-gcm-decrypt: failed to set the authentication tag");
  }
  int finlen = 0;
  int ok = EVP_CipherFinal_ex(ctx, outbuf + total, &finlen);
  EVP_CIPHER_CTX_free(ctx);
  if (ok != 1) cvm_abort("aes-256-gcm-decrypt: authentication failed (tag mismatch)");
  total += finlen;

  return bytevector_value(outbuf, total);
}

void cvm_register_cipher_builtins(VM *vm) {
  cvm_register_builtin(vm, "aes-256-gcm-encrypt", bi_aes_256_gcm_encrypt);
  cvm_register_builtin(vm, "aes-256-gcm-decrypt", bi_aes_256_gcm_decrypt);
  cvm_register_builtin(vm, "aes-256-gcm-random-key", bi_aes_256_gcm_random_key);
  cvm_register_builtin(vm, "aes-256-gcm-random-nonce", bi_aes_256_gcm_random_nonce);
}
