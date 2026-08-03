/* (creme pkey) — see pkey.h. A port of src/creme/modules/creme/pkey.cr:
 * rsa-generate-key/ec-generate-key/pkey-sign/pkey-verify/rsa-encrypt/
 * rsa-decrypt/pkey->pem/pem->pkey/pkey-public-key/pkey?/pkey-private?/
 * pkey-type. Unlike native (which has to reuse the vendored jose.cr
 * shard's own reopened LibCryptoJose bindings, since Crystal's stdlib has
 * no OpenSSL::PKey class hierarchy at all), the full EVP_PKEY/RSA/
 * EC_KEY/PEM C API is simply part of <openssl/evp.h>/<openssl/rsa.h>/
 * <openssl/ec.h>/<openssl/pem.h> already -- already linked via
 * -lcrypto, the same link (creme digest)'s EVP_Digest/HMAC, (creme
 * cipher)'s EVP AEAD calls, and (creme actor)'s handshake all use.
 *
 * A pkey handle (BOX_KIND_PKEY) is a small PKeyBox struct holding the
 * key's own PEM text (plus a kind/is-private flag) -- never a live
 * EVP_PKEY/RSA/EC_KEY* held persistently, mirroring native's own
 * PKeyHandle exactly (see that file's own header comment for why): every
 * sign/verify/encrypt/decrypt/pkey->pem call below reconstructs a
 * transient native key from the stored PEM, performs the one operation,
 * and frees it immediately.
 *
 * Same EVP_CIPHER_CTX-style resource-cleanup discipline (creme cipher)'s
 * own icecreme/cipher.c established: creme_abort longjmps past any C++-style
 * RAII that doesn't exist in C, so every error branch below explicitly
 * frees whatever OpenSSL resource it opened first. */
#include "builtin_config.h"

#if CREME_WITH_PKEY

#include <gc.h>
#include <openssl/bio.h>
#include <openssl/ec.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/rsa.h>
#include <string.h>

#include "embed.h"
#include "pkey.h"

/* The low-level RSA/EC_KEY pointer API (RSA_free/EC_KEY_free, EVP_PKEY_set1_RSA/
 * EC_KEY, and the RSA/EC_KEY-typed PEM_read/write_bio_* functions) is
 * marked deprecated in OpenSSL 3.0+ in favor of an EVP_PKEY-only
 * workflow, but remains fully functional and is exactly what's needed to
 * build/read a SPECIFIC key type before wrapping it into a generic
 * EVP_PKEY -- the vendored jose.cr shard's own FFI bindings (lib/jose/
 * src/jose/lib_crypto.cr) use the identical API for the identical
 * reason. Silenced here rather than reworked onto OpenSSL 3.0's newer
 * EVP_PKEY_fromdata API, which would be a much larger rewrite for no
 * behavior change. */
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"

static PKeyBox *pkey_arg(Value v, const char *who) {
  return creme_arg_box(&v, 1, 0, BOX_KIND_PKEY, who);
}

static Value pkey_box(int kind, int is_private, const char *pem, int pem_len) {
  PKeyBox *box = GC_MALLOC(sizeof(PKeyBox));
  box->kind = kind;
  box->is_private = is_private;
  box->pem = (char *)pem;
  box->pem_len = pem_len;
  return v_box(box, BOX_KIND_PKEY);
}

/* ---- PEM <-> native key helpers ------------------------------------------ */

static char *bio_to_gc_string(BIO *bio, int *len_out) {
  char *data_ptr = NULL;
  long len = BIO_get_mem_data(bio, &data_ptr);
  char *buf = GC_MALLOC((size_t)len + 1);
  memcpy(buf, data_ptr, (size_t)len);
  buf[len] = '\0';
  *len_out = (int)len;
  return buf;
}

static char *rsa_to_pem(RSA *rsa, int is_private, int *len_out, const char *who) {
  BIO *bio = BIO_new(BIO_s_mem());
  if (!bio) creme_abort("%s: BIO_new failed", who);
  int ret = is_private ? PEM_write_bio_RSAPrivateKey(bio, rsa, NULL, NULL, 0, NULL, NULL) : PEM_write_bio_RSA_PUBKEY(bio, rsa);
  if (ret != 1) {
    BIO_free(bio);
    creme_abort("%s: failed to write RSA PEM", who);
  }
  char *pem = bio_to_gc_string(bio, len_out);
  BIO_free(bio);
  return pem;
}

static char *ec_to_pem(EC_KEY *ec, int is_private, int *len_out, const char *who) {
  BIO *bio = BIO_new(BIO_s_mem());
  if (!bio) creme_abort("%s: BIO_new failed", who);
  int ret = is_private ? PEM_write_bio_ECPrivateKey(bio, ec, NULL, NULL, 0, NULL, NULL) : PEM_write_bio_EC_PUBKEY(bio, ec);
  if (ret != 1) {
    BIO_free(bio);
    creme_abort("%s: failed to write EC PEM", who);
  }
  char *pem = bio_to_gc_string(bio, len_out);
  BIO_free(bio);
  return pem;
}

/* Exported for (creme x509)'s x509-cert-public-key, so it can wrap a
 * public RSA/EC_KEY* it extracted from a certificate (via
 * X509_get_pubkey + EVP_PKEY_get1_RSA/EC_KEY) into a (creme pkey) box
 * without duplicating rsa_to_pem/ec_to_pem/pkey_box here. */
Value creme_pkey_box_public_rsa(RSA *rsa) {
  int pem_len;
  char *pem = rsa_to_pem(rsa, 0, &pem_len, "x509-cert-public-key");
  return pkey_box(PKEY_KIND_RSA, 0, pem, pem_len);
}

Value creme_pkey_box_public_ec(EC_KEY *ec) {
  int pem_len;
  char *pem = ec_to_pem(ec, 0, &pem_len, "x509-cert-public-key");
  return pkey_box(PKEY_KIND_EC, 0, pem, pem_len);
}

static RSA *pem_try_rsa_private(const char *pem, int pem_len) {
  BIO *bio = BIO_new_mem_buf(pem, pem_len);
  RSA *rsa = PEM_read_bio_RSAPrivateKey(bio, NULL, NULL, NULL);
  BIO_free(bio);
  return rsa;
}

static RSA *pem_try_rsa_public(const char *pem, int pem_len) {
  BIO *bio = BIO_new_mem_buf(pem, pem_len);
  RSA *rsa = PEM_read_bio_RSA_PUBKEY(bio, NULL, NULL, NULL);
  BIO_free(bio);
  return rsa;
}

static EC_KEY *pem_try_ec_private(const char *pem, int pem_len) {
  BIO *bio = BIO_new_mem_buf(pem, pem_len);
  EC_KEY *ec = PEM_read_bio_ECPrivateKey(bio, NULL, NULL, NULL);
  BIO_free(bio);
  return ec;
}

static EC_KEY *pem_try_ec_public(const char *pem, int pem_len) {
  BIO *bio = BIO_new_mem_buf(pem, pem_len);
  EC_KEY *ec = PEM_read_bio_EC_PUBKEY(bio, NULL, NULL, NULL);
  BIO_free(bio);
  return ec;
}

static RSA *pem_to_rsa(const char *pem, int pem_len, const char *who) {
  RSA *rsa = pem_try_rsa_private(pem, pem_len);
  if (rsa) return rsa;
  rsa = pem_try_rsa_public(pem, pem_len);
  if (rsa) return rsa;
  creme_abort("%s: not a recognizable RSA PEM key", who);
}

static EC_KEY *pem_to_ec(const char *pem, int pem_len, const char *who) {
  EC_KEY *ec = pem_try_ec_private(pem, pem_len);
  if (ec) return ec;
  ec = pem_try_ec_public(pem, pem_len);
  if (ec) return ec;
  creme_abort("%s: not a recognizable EC PEM key", who);
}

static EVP_PKEY *pkeybox_to_evp(PKeyBox *box, const char *who) {
  /* Parse the key material BEFORE allocating the EVP_PKEY, so an abort inside
   * pem_to_rsa/pem_to_ec (unparseable PEM) has nothing to leak. */
  EVP_PKEY *pkey;
  if (box->kind == PKEY_KIND_RSA) {
    RSA *rsa = pem_to_rsa(box->pem, box->pem_len, who);
    pkey = EVP_PKEY_new();
    if (!pkey) { RSA_free(rsa); creme_abort("%s: EVP_PKEY_new failed", who); }
    int ok = EVP_PKEY_set1_RSA(pkey, rsa);
    RSA_free(rsa);
    if (ok != 1) { EVP_PKEY_free(pkey); creme_abort("%s: failed to assemble RSA key", who); }
  } else {
    EC_KEY *ec = pem_to_ec(box->pem, box->pem_len, who);
    pkey = EVP_PKEY_new();
    if (!pkey) { EC_KEY_free(ec); creme_abort("%s: EVP_PKEY_new failed", who); }
    int ok = EVP_PKEY_set1_EC_KEY(pkey, ec);
    EC_KEY_free(ec);
    if (ok != 1) { EVP_PKEY_free(pkey); creme_abort("%s: failed to assemble EC key", who); }
  }
  return pkey;
}

static int ec_curve_nid(const char *curve, const char *who) {
  if (strcmp(curve, "p256") == 0) return NID_X9_62_prime256v1;
  if (strcmp(curve, "p384") == 0) return NID_secp384r1;
  if (strcmp(curve, "p521") == 0) return NID_secp521r1;
  creme_abort("%s: unknown curve '%s' (expected p256, p384, or p521)", who, curve);
}

/* ---- generation ----------------------------------------------------------- */

static Value bi_rsa_generate_key(VM *vm, Value *args, int nargs) {
  (void)vm;
  int bits = 2048;
  if (nargs >= 1) {
    if (args[0].tag != T_INT) creme_abort("rsa-generate-key: expected an integer bit count");
    bits = (int)args[0].as.i;
  }
  if (bits < 2048) creme_abort("rsa-generate-key: bits must be at least 2048, got %d", bits);

  RSA *rsa = RSA_new();
  if (!rsa) creme_abort("rsa-generate-key: RSA_new failed");
  BIGNUM *e = BN_new();
  if (!e) {
    RSA_free(rsa);
    creme_abort("rsa-generate-key: BN_new failed");
  }
  BN_set_word(e, RSA_F4);
  int ret = RSA_generate_key_ex(rsa, bits, e, NULL);
  BN_free(e);
  if (ret != 1) {
    RSA_free(rsa);
    creme_abort("rsa-generate-key: RSA_generate_key_ex failed");
  }
  int pem_len;
  char *pem = rsa_to_pem(rsa, 1, &pem_len, "rsa-generate-key");
  RSA_free(rsa);
  return pkey_box(PKEY_KIND_RSA, 1, pem, pem_len);
}

static Value bi_ec_generate_key(VM *vm, Value *args, int nargs) {
  (void)vm;
  const char *curve = "p256";
  if (nargs >= 1) {
    if (args[0].tag != T_SYM) creme_abort("ec-generate-key: expected a symbol");
    curve = args[0].as.chars;
  }
  int nid = ec_curve_nid(curve, "ec-generate-key");

  EC_KEY *key = EC_KEY_new_by_curve_name(nid);
  if (!key) creme_abort("ec-generate-key: EC_KEY_new_by_curve_name failed");
  if (EC_KEY_generate_key(key) != 1) {
    EC_KEY_free(key);
    creme_abort("ec-generate-key: EC_KEY_generate_key failed");
  }
  int pem_len;
  char *pem = ec_to_pem(key, 1, &pem_len, "ec-generate-key");
  EC_KEY_free(key);
  return pkey_box(PKEY_KIND_EC, 1, pem, pem_len);
}

/* ---- predicates/accessors -------------------------------------------------- */

static Value bi_pkey_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "pkey?");
  return v_bool(args[0].tag == T_BOX && args[0].aux == BOX_KIND_PKEY);
}

static Value bi_pkey_private_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "pkey-private?");
  return v_bool(pkey_arg(args[0], "pkey-private?")->is_private);
}

static Value bi_pkey_type(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "pkey-type");
  PKeyBox *box = pkey_arg(args[0], "pkey-type");
  return creme_sym_lit(box->kind == PKEY_KIND_RSA ? "rsa" : "ec");
}

static Value bi_pkey_public_key(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "pkey-public-key");
  PKeyBox *box = pkey_arg(args[0], "pkey-public-key");
  if (!box->is_private) return pkey_box(box->kind, 0, box->pem, box->pem_len);

  int pem_len;
  char *pem;
  if (box->kind == PKEY_KIND_RSA) {
    RSA *rsa = pem_to_rsa(box->pem, box->pem_len, "pkey-public-key");
    pem = rsa_to_pem(rsa, 0, &pem_len, "pkey-public-key");
    RSA_free(rsa);
  } else {
    EC_KEY *ec = pem_to_ec(box->pem, box->pem_len, "pkey-public-key");
    pem = ec_to_pem(ec, 0, &pem_len, "pkey-public-key");
    EC_KEY_free(ec);
  }
  return pkey_box(box->kind, 0, pem, pem_len);
}

/* ---- PEM import/export ----------------------------------------------------- */

static Value bi_pkey_to_pem(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "pkey->pem");
  PKeyBox *box = pkey_arg(args[0], "pkey->pem");
  return v_str(box->pem, box->pem_len);
}

static Value bi_pem_to_pkey(VM *vm, Value *args, int nargs) {
  (void)vm;
  const char *pem = creme_arg_cstr(args, nargs, 0, "pem->pkey");
  int pem_len = args[0].aux;

  RSA *rsa = pem_try_rsa_private(pem, pem_len);
  if (rsa) {
    RSA_free(rsa);
    return pkey_box(PKEY_KIND_RSA, 1, pem, pem_len);
  }
  rsa = pem_try_rsa_public(pem, pem_len);
  if (rsa) {
    RSA_free(rsa);
    return pkey_box(PKEY_KIND_RSA, 0, pem, pem_len);
  }
  EC_KEY *ec = pem_try_ec_private(pem, pem_len);
  if (ec) {
    EC_KEY_free(ec);
    return pkey_box(PKEY_KIND_EC, 1, pem, pem_len);
  }
  ec = pem_try_ec_public(pem, pem_len);
  if (ec) {
    EC_KEY_free(ec);
    return pkey_box(PKEY_KIND_EC, 0, pem, pem_len);
  }
  creme_abort("pem->pkey: not a recognizable RSA/EC PEM key");
}

/* ---- sign/verify (shared across RSA and EC) -------------------------------- */

static Value bi_pkey_sign(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "pkey-sign");
  PKeyBox *box = pkey_arg(args[0], "pkey-sign");
  if (!box->is_private) creme_abort("pkey-sign: expected a private key");
  int msg_len;
  const unsigned char *msg = creme_arg_blob(args, nargs, 1, "pkey-sign", &msg_len);

  EVP_PKEY *pkey = pkeybox_to_evp(box, "pkey-sign");
  EVP_MD_CTX *ctx = EVP_MD_CTX_new();
  if (!ctx) {
    EVP_PKEY_free(pkey);
    creme_abort("pkey-sign: EVP_MD_CTX_new failed");
  }
  if (EVP_DigestSignInit(ctx, NULL, EVP_sha256(), NULL, pkey) != 1) {
    EVP_MD_CTX_free(ctx);
    EVP_PKEY_free(pkey);
    creme_abort("pkey-sign: EVP_DigestSignInit failed");
  }
  if (EVP_DigestSignUpdate(ctx, msg, (size_t)msg_len) != 1) {
    EVP_MD_CTX_free(ctx);
    EVP_PKEY_free(pkey);
    creme_abort("pkey-sign: EVP_DigestSignUpdate failed");
  }
  size_t sig_len = 0;
  EVP_DigestSignFinal(ctx, NULL, &sig_len);
  unsigned char *sig = GC_MALLOC(sig_len);
  if (EVP_DigestSignFinal(ctx, sig, &sig_len) != 1) {
    EVP_MD_CTX_free(ctx);
    EVP_PKEY_free(pkey);
    creme_abort("pkey-sign: EVP_DigestSignFinal failed");
  }
  EVP_MD_CTX_free(ctx);
  EVP_PKEY_free(pkey);
  return creme_bytevector_wrap(sig, (int)sig_len);
}

static Value bi_pkey_verify(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 3, "pkey-verify");
  PKeyBox *box = pkey_arg(args[0], "pkey-verify");
  int msg_len, sig_len;
  const unsigned char *msg = creme_arg_blob(args, nargs, 1, "pkey-verify", &msg_len);
  const unsigned char *sig = creme_arg_blob(args, nargs, 2, "pkey-verify", &sig_len);

  EVP_PKEY *pkey = pkeybox_to_evp(box, "pkey-verify");
  EVP_MD_CTX *ctx = EVP_MD_CTX_new();
  if (!ctx) {
    EVP_PKEY_free(pkey);
    creme_abort("pkey-verify: EVP_MD_CTX_new failed");
  }
  if (EVP_DigestVerifyInit(ctx, NULL, EVP_sha256(), NULL, pkey) != 1) {
    EVP_MD_CTX_free(ctx);
    EVP_PKEY_free(pkey);
    creme_abort("pkey-verify: EVP_DigestVerifyInit failed");
  }
  if (EVP_DigestVerifyUpdate(ctx, msg, (size_t)msg_len) != 1) {
    EVP_MD_CTX_free(ctx);
    EVP_PKEY_free(pkey);
    creme_abort("pkey-verify: EVP_DigestVerifyUpdate failed");
  }
  int ok = EVP_DigestVerifyFinal(ctx, sig, (size_t)sig_len);
  EVP_MD_CTX_free(ctx);
  EVP_PKEY_free(pkey);
  return v_bool(ok == 1);
}

/* ---- RSA-OAEP-SHA256 encryption only (see pkey.cr's own header comment on
 * why no legacy PKCS1v1.5 encryption padding is offered) -------------------- */

static unsigned char *rsa_oaep_op(RSA *rsa, const unsigned char *input, int input_len, int encrypt, int *out_len,
                                   const char *who) {
  EVP_PKEY *pkey = EVP_PKEY_new();
  if (!pkey) creme_abort("%s: EVP_PKEY_new failed", who);
  if (EVP_PKEY_set1_RSA(pkey, rsa) != 1) { EVP_PKEY_free(pkey); creme_abort("%s: failed to assemble RSA key", who); }
  EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new(pkey, NULL);
  if (!ctx) {
    EVP_PKEY_free(pkey);
    creme_abort("%s: EVP_PKEY_CTX_new failed", who);
  }
  int init_ok = encrypt ? EVP_PKEY_encrypt_init(ctx) : EVP_PKEY_decrypt_init(ctx);
  if (init_ok != 1) {
    EVP_PKEY_CTX_free(ctx);
    EVP_PKEY_free(pkey);
    creme_abort("%s: EVP_PKEY_%s_init failed", who, encrypt ? "encrypt" : "decrypt");
  }
  if (EVP_PKEY_CTX_set_rsa_padding(ctx, RSA_PKCS1_OAEP_PADDING) <= 0) {
    EVP_PKEY_CTX_free(ctx);
    EVP_PKEY_free(pkey);
    creme_abort("%s: failed to set OAEP padding", who);
  }
  if (EVP_PKEY_CTX_set_rsa_oaep_md(ctx, EVP_sha256()) <= 0) {
    EVP_PKEY_CTX_free(ctx);
    EVP_PKEY_free(pkey);
    creme_abort("%s: failed to set OAEP digest", who);
  }
  if (EVP_PKEY_CTX_set_rsa_mgf1_md(ctx, EVP_sha256()) <= 0) {
    EVP_PKEY_CTX_free(ctx);
    EVP_PKEY_free(pkey);
    creme_abort("%s: failed to set MGF1 digest", who);
  }

  size_t outlen = 0;
  int step1 = encrypt ? EVP_PKEY_encrypt(ctx, NULL, &outlen, input, (size_t)input_len)
                       : EVP_PKEY_decrypt(ctx, NULL, &outlen, input, (size_t)input_len);
  if (step1 != 1) {
    EVP_PKEY_CTX_free(ctx);
    EVP_PKEY_free(pkey);
    creme_abort("%s: failed to determine output length", who);
  }
  unsigned char *out_buf = GC_MALLOC(outlen ? outlen : 1);
  int step2 = encrypt ? EVP_PKEY_encrypt(ctx, out_buf, &outlen, input, (size_t)input_len)
                       : EVP_PKEY_decrypt(ctx, out_buf, &outlen, input, (size_t)input_len);
  EVP_PKEY_CTX_free(ctx);
  EVP_PKEY_free(pkey);
  if (step2 != 1) {
    if (encrypt) {
      creme_abort("%s: EVP_PKEY_encrypt failed", who);
    } else {
      creme_abort("%s: decryption failed (wrong key, or corrupted/truncated ciphertext)", who);
    }
  }
  *out_len = (int)outlen;
  return out_buf;
}

static Value bi_rsa_encrypt(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "rsa-encrypt");
  PKeyBox *box = pkey_arg(args[0], "rsa-encrypt");
  if (box->kind != PKEY_KIND_RSA) creme_abort("rsa-encrypt: expected an RSA key");
  int pt_len;
  const unsigned char *pt = creme_arg_blob(args, nargs, 1, "rsa-encrypt", &pt_len);

  RSA *rsa = pem_to_rsa(box->pem, box->pem_len, "rsa-encrypt");
  int out_len;
  unsigned char *out = rsa_oaep_op(rsa, pt, pt_len, 1, &out_len, "rsa-encrypt");
  RSA_free(rsa);
  return creme_bytevector_wrap(out, out_len);
}

static Value bi_rsa_decrypt(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "rsa-decrypt");
  PKeyBox *box = pkey_arg(args[0], "rsa-decrypt");
  if (box->kind != PKEY_KIND_RSA) creme_abort("rsa-decrypt: expected an RSA key");
  if (!box->is_private) creme_abort("rsa-decrypt: expected a private key");
  int ct_len;
  const unsigned char *ct = creme_arg_blob(args, nargs, 1, "rsa-decrypt", &ct_len);

  RSA *rsa = pem_to_rsa(box->pem, box->pem_len, "rsa-decrypt");
  int out_len;
  unsigned char *out = rsa_oaep_op(rsa, ct, ct_len, 0, &out_len, "rsa-decrypt");
  RSA_free(rsa);
  return creme_bytevector_wrap(out, out_len);
}

void creme_register_pkey_builtins(VM *vm) {
  creme_register_builtin(vm, "rsa-generate-key", bi_rsa_generate_key);
  creme_register_builtin(vm, "ec-generate-key", bi_ec_generate_key);
  creme_register_builtin(vm, "pkey?", bi_pkey_p);
  creme_register_builtin(vm, "pkey-private?", bi_pkey_private_p);
  creme_register_builtin(vm, "pkey-type", bi_pkey_type);
  creme_register_builtin(vm, "pkey-public-key", bi_pkey_public_key);
  creme_register_builtin(vm, "pkey->pem", bi_pkey_to_pem);
  creme_register_builtin(vm, "pem->pkey", bi_pem_to_pkey);
  creme_register_builtin(vm, "pkey-sign", bi_pkey_sign);
  creme_register_builtin(vm, "pkey-verify", bi_pkey_verify);
  creme_register_builtin(vm, "rsa-encrypt", bi_rsa_encrypt);
  creme_register_builtin(vm, "rsa-decrypt", bi_rsa_decrypt);
}

#endif /* CREME_WITH_PKEY */
