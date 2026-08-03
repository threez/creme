/* (creme x509) — see x509.h. A port of src/creme/modules/creme/x509.cr:
 * x509-self-signed-certificate/x509-create-csr/x509-sign-csr/
 * x509-cert->pem/pem->x509-cert/x509-cert-subject/x509-cert-issuer/
 * x509-cert-public-key/x509-cert-not-before/x509-cert-not-after/
 * x509-verify-chain. Unlike native (which has to reopen Crystal's own
 * OpenSSL::LibCrypto binding to add every X509_ and ASN1_ declaration it
 * needs, since neither Crystal's stdlib nor the vendored jose.cr shard
 * bind a certificate-building/chain-verification surface), the full
 * X509/X509_REQ/X509_STORE C API is simply part of <openssl/x509.h>/
 * <openssl/x509v3.h>/<openssl/pem.h>/<openssl/asn1.h> already -- already
 * linked via -lcrypto, the same link (creme pkey)'s own icecreme/pkey.c uses.
 *
 * An x509-cert/x509-csr handle (BOX_KIND_X509_CERT/_CSR) holds the
 * cert/CSR's own PEM text -- never a live X509/X509_REQ pointer held
 * persistently, the same design (creme pkey)'s own PKeyBox uses (see
 * that file's own header comment for why): every operation below
 * reconstructs a transient native object from the stored PEM, performs
 * the one operation, and frees it immediately.
 *
 * Same resource-cleanup discipline (creme cipher)/(creme pkey) already
 * established: creme_abort longjmps past any C++-style RAII that doesn't
 * exist in C, so every error branch below explicitly frees whatever
 * OpenSSL resource it opened first. */
#include "builtin_config.h"

#if CREME_WITH_X509

#include <gc.h>
#include <openssl/asn1.h>
#include <openssl/bio.h>
#include <openssl/ec.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/rsa.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <string.h>

#include "embed.h"
#include "pkey.h"
#include "x509.h"

/* Same low-level-API deprecation note as pkey.c's own header comment --
 * silenced here for the identical reason (RSA/EC_KEY-typed PEM I/O and
 * EVP_PKEY_get1_RSA/EC_KEY, needed to build a (creme pkey) box from a
 * certificate's own public key). */
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"

#define X509_CERT_SERIAL_SELF_SIGNED 1
#define X509_CERT_SERIAL_CA_SIGNED 2
#define NID_BASIC_CONSTRAINTS_ 87

/* ---- Value helpers (matching cipher.c/digest.c/pkey.c's own per-file style) */

static Value str_lit(const char *s) { return v_str(s, (int)strlen(s)); }

static Value cons2(Value car, Value cdr) {
  Pair *p = GC_MALLOC(sizeof(Pair));
  p->car = car;
  p->cdr = cdr;
  return v_pair(p);
}

static Value alist_pair(const char *key, Value val) { return cons2(str_lit(key), val); }

static char *gc_strndup(const char *s, int len) {
  char *buf = GC_MALLOC((size_t)len + 1);
  memcpy(buf, s, (size_t)len);
  buf[len] = '\0';
  return buf;
}

static Value x509_cert_box(const char *pem, int pem_len) {
  char *pem_buf = gc_strndup(pem, pem_len);
  Value v;
  v.tag = T_BOX;
  v.aux = BOX_KIND_X509_CERT;
  v.as.ptr = pem_buf;
  return v;
}

static Value x509_csr_box(const char *pem, int pem_len) {
  char *pem_buf = gc_strndup(pem, pem_len);
  Value v;
  v.tag = T_BOX;
  v.aux = BOX_KIND_X509_CSR;
  v.as.ptr = pem_buf;
  return v;
}

static const char *x509_cert_arg(Value v, const char *who) {
  return creme_arg_box(&v, 1, 0, BOX_KIND_X509_CERT, who);
}

static const char *x509_csr_arg(Value v, const char *who) {
  return creme_arg_box(&v, 1, 0, BOX_KIND_X509_CSR, who);
}

static PKeyBox *pkey_arg(Value v, const char *who) {
  return creme_arg_box(&v, 1, 0, BOX_KIND_PKEY, who);
}

/* ---- PEM helpers ----------------------------------------------------------- */

static char *bio_to_gc_string(BIO *bio, int *len_out) {
  char *data_ptr = NULL;
  long len = BIO_get_mem_data(bio, &data_ptr);
  char *buf = GC_MALLOC((size_t)len + 1);
  memcpy(buf, data_ptr, (size_t)len);
  buf[len] = '\0';
  *len_out = (int)len;
  return buf;
}

static char *x509_cert_to_pem(X509 *cert, int *len_out, const char *who) {
  BIO *bio = BIO_new(BIO_s_mem());
  if (!bio) creme_abort("%s: BIO_new failed", who);
  if (PEM_write_bio_X509(bio, cert) != 1) {
    BIO_free(bio);
    creme_abort("%s: failed to write certificate PEM", who);
  }
  char *pem = bio_to_gc_string(bio, len_out);
  BIO_free(bio);
  return pem;
}

static char *x509_csr_to_pem(X509_REQ *req, int *len_out, const char *who) {
  BIO *bio = BIO_new(BIO_s_mem());
  if (!bio) creme_abort("%s: BIO_new failed", who);
  if (PEM_write_bio_X509_REQ(bio, req) != 1) {
    BIO_free(bio);
    creme_abort("%s: failed to write CSR PEM", who);
  }
  char *pem = bio_to_gc_string(bio, len_out);
  BIO_free(bio);
  return pem;
}

static X509 *x509_pem_to_cert(const char *pem, int pem_len, const char *who) {
  BIO *bio = BIO_new_mem_buf(pem, pem_len);
  X509 *cert = PEM_read_bio_X509(bio, NULL, NULL, NULL);
  BIO_free(bio);
  if (!cert) creme_abort("%s: not a recognizable X.509 certificate PEM", who);
  return cert;
}

static X509_REQ *x509_pem_to_csr(const char *pem, int pem_len, const char *who) {
  BIO *bio = BIO_new_mem_buf(pem, pem_len);
  X509_REQ *req = PEM_read_bio_X509_REQ(bio, NULL, NULL, NULL);
  BIO_free(bio);
  if (!req) creme_abort("%s: not a recognizable CSR PEM", who);
  return req;
}

static RSA *pkey_pem_to_rsa(const char *pem, int pem_len, const char *who) {
  BIO *bio = BIO_new_mem_buf(pem, pem_len);
  RSA *rsa = PEM_read_bio_RSAPrivateKey(bio, NULL, NULL, NULL);
  BIO_free(bio);
  if (!rsa) creme_abort("%s: not a recognizable RSA private key PEM", who);
  return rsa;
}

static EC_KEY *pkey_pem_to_ec(const char *pem, int pem_len, const char *who) {
  BIO *bio = BIO_new_mem_buf(pem, pem_len);
  EC_KEY *ec = PEM_read_bio_ECPrivateKey(bio, NULL, NULL, NULL);
  BIO_free(bio);
  if (!ec) creme_abort("%s: not a recognizable EC private key PEM", who);
  return ec;
}

static EVP_PKEY *pkeybox_to_evp(PKeyBox *box, const char *who) {
  EVP_PKEY *pkey = EVP_PKEY_new();
  if (!pkey) creme_abort("%s: EVP_PKEY_new failed", who);
  if (box->kind == PKEY_KIND_RSA) {
    RSA *rsa = pkey_pem_to_rsa(box->pem, box->pem_len, who);
    EVP_PKEY_set1_RSA(pkey, rsa);
    RSA_free(rsa);
  } else {
    EC_KEY *ec = pkey_pem_to_ec(box->pem, box->pem_len, who);
    EVP_PKEY_set1_EC_KEY(pkey, ec);
    EC_KEY_free(ec);
  }
  return pkey;
}

/* ---- subject/issuer name helpers -------------------------------------------- */

typedef struct {
  const char *field;
  int nid;
} SubjectNid;

static const SubjectNid SUBJECT_NIDS[] = {
    {"CN", NID_commonName},          {"O", NID_organizationName},   {"OU", NID_organizationalUnitName},
    {"C", NID_countryName},          {"L", NID_localityName},       {"ST", NID_stateOrProvinceName},
    {"emailAddress", NID_pkcs9_emailAddress},
};
#define N_SUBJECT_NIDS (int)(sizeof(SUBJECT_NIDS) / sizeof(SUBJECT_NIDS[0]))

static X509_NAME *x509_build_name(Value subject, const char *who) {
  if (subject.tag != T_PAIR && subject.tag != T_NIL) creme_abort("%s: expected an alist of (field . value) pairs", who);
  X509_NAME *name = X509_NAME_new();
  for (Value cur = subject; cur.tag == T_PAIR; cur = cur.as.pair->cdr) {
    Value pair = cur.as.pair->car;
    if (pair.tag != T_PAIR || pair.as.pair->car.tag != T_STR || pair.as.pair->cdr.tag != T_STR) {
      X509_NAME_free(name);
      creme_abort("%s: expected an alist of (field . value) pairs", who);
    }
    Value field = pair.as.pair->car;
    Value value = pair.as.pair->cdr;
    char *field_str = gc_strndup(field.as.chars, field.aux);
    int ret = X509_NAME_add_entry_by_txt(name, field_str, MBSTRING_UTF8, (const unsigned char *)value.as.chars, value.aux, -1, 0);
    if (ret != 1) {
      X509_NAME_free(name);
      creme_abort("%s: invalid subject field '%s'", who, field_str);
    }
  }
  return name;
}

static Value x509_name_alist(X509_NAME *name) {
  unsigned char buf[256];
  Value result = v_nil();
  int n_pairs = 0;
  Value pairs[N_SUBJECT_NIDS];
  for (int i = 0; i < N_SUBJECT_NIDS; i++) {
    int idx = X509_NAME_get_index_by_NID(name, SUBJECT_NIDS[i].nid, -1);
    if (idx < 0) continue;
    int n = X509_NAME_get_text_by_NID(name, SUBJECT_NIDS[i].nid, (char *)buf, (int)sizeof(buf));
    if (n < 0) continue;
    pairs[n_pairs++] = alist_pair(SUBJECT_NIDS[i].field, creme_bytes_value((const char *)buf, n));
  }
  for (int i = n_pairs - 1; i >= 0; i--) result = cons2(pairs[i], result);
  return result;
}

static void x509_add_ca_extension(X509 *cert, const char *who) {
  X509_EXTENSION *ext = X509V3_EXT_nconf_nid(NULL, NULL, NID_BASIC_CONSTRAINTS_, "critical,CA:TRUE");
  if (!ext) creme_abort("%s: failed to build basicConstraints extension", who);
  X509_add_ext(cert, ext, -1);
  X509_EXTENSION_free(ext);
}

/* civil_from_days-style epoch conversion (Howard Hinnant's well-known
 * algorithm) -- avoids depending on timegm(3), which needs different
 * feature-test macros/isn't declared identically across glibc/musl/
 * BSD libc, for one small self-contained UTC-only calculation. ASN1_TIME
 * is always UTC, so no timezone handling is needed at all. */
static long long days_from_civil(long long y, int m, int d) {
  y -= m <= 2;
  long long era = (y >= 0 ? y : y - 399) / 400;
  long long yoe = y - era * 400;
  long long doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
  long long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097 + doe - 719468;
}

static long long tm_to_epoch(struct tm *tm) {
  long long days = days_from_civil(tm->tm_year + 1900, tm->tm_mon + 1, tm->tm_mday);
  return days * 86400LL + tm->tm_hour * 3600LL + tm->tm_min * 60LL + tm->tm_sec;
}

static long long x509_asn1_time_to_epoch(const ASN1_TIME *t, const char *who) {
  struct tm tm;
  if (ASN1_TIME_to_tm(t, &tm) != 1) creme_abort("%s: ASN1_TIME_to_tm failed", who);
  return tm_to_epoch(&tm);
}

/* ---- certificate/CSR generation --------------------------------------------- */

static Value bi_x509_self_signed_certificate(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "x509-self-signed-certificate");
  PKeyBox *key = pkey_arg(args[0], "x509-self-signed-certificate");
  if (!key->is_private) creme_abort("x509-self-signed-certificate: expected a private key");
  long days = 365;
  if (nargs >= 3) {
    if (args[2].tag != T_INT) creme_abort("x509-self-signed-certificate: expected an integer for days");
    days = (long)args[2].as.i;
  }

  EVP_PKEY *pkey = pkeybox_to_evp(key, "x509-self-signed-certificate");
  X509_NAME *name = x509_build_name(args[1], "x509-self-signed-certificate");

  X509 *cert = X509_new();
  X509_set_version(cert, 2);
  ASN1_INTEGER_set(X509_get_serialNumber(cert), X509_CERT_SERIAL_SELF_SIGNED);
  X509_gmtime_adj(X509_getm_notBefore(cert), 0);
  X509_gmtime_adj(X509_getm_notAfter(cert), days * 24 * 3600);
  X509_set_pubkey(cert, pkey);
  X509_set_subject_name(cert, name);
  X509_set_issuer_name(cert, name);
  x509_add_ca_extension(cert, "x509-self-signed-certificate");
  int ret = X509_sign(cert, pkey, EVP_sha256());
  X509_NAME_free(name);
  EVP_PKEY_free(pkey);
  if (ret == 0) {
    X509_free(cert);
    creme_abort("x509-self-signed-certificate: X509_sign failed");
  }
  int pem_len;
  char *pem = x509_cert_to_pem(cert, &pem_len, "x509-self-signed-certificate");
  X509_free(cert);
  return x509_cert_box(pem, pem_len);
}

static Value bi_x509_create_csr(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "x509-create-csr");
  PKeyBox *key = pkey_arg(args[0], "x509-create-csr");
  if (!key->is_private) creme_abort("x509-create-csr: expected a private key");

  EVP_PKEY *pkey = pkeybox_to_evp(key, "x509-create-csr");
  X509_NAME *name = x509_build_name(args[1], "x509-create-csr");

  X509_REQ *req = X509_REQ_new();
  X509_REQ_set_version(req, 0);
  X509_REQ_set_subject_name(req, name);
  X509_REQ_set_pubkey(req, pkey);
  int ret = X509_REQ_sign(req, pkey, EVP_sha256());
  X509_NAME_free(name);
  EVP_PKEY_free(pkey);
  if (ret == 0) {
    X509_REQ_free(req);
    creme_abort("x509-create-csr: X509_REQ_sign failed");
  }
  int pem_len;
  char *pem = x509_csr_to_pem(req, &pem_len, "x509-create-csr");
  X509_REQ_free(req);
  return x509_csr_box(pem, pem_len);
}

static Value bi_x509_sign_csr(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 3, "x509-sign-csr");
  const char *csr_pem = x509_csr_arg(args[0], "x509-sign-csr");
  const char *ca_cert_pem = x509_cert_arg(args[1], "x509-sign-csr");
  PKeyBox *ca_key = pkey_arg(args[2], "x509-sign-csr");
  if (!ca_key->is_private) creme_abort("x509-sign-csr: expected a private CA key");
  long days = 365;
  if (nargs >= 4) {
    if (args[3].tag != T_INT) creme_abort("x509-sign-csr: expected an integer for days");
    days = (long)args[3].as.i;
  }

  X509_REQ *req = x509_pem_to_csr(csr_pem, (int)strlen(csr_pem), "x509-sign-csr");
  X509 *ca_cert = x509_pem_to_cert(ca_cert_pem, (int)strlen(ca_cert_pem), "x509-sign-csr");
  EVP_PKEY *ca_pkey = pkeybox_to_evp(ca_key, "x509-sign-csr");
  EVP_PKEY *req_pubkey = X509_REQ_get_pubkey(req);
  if (!req_pubkey) {
    X509_REQ_free(req);
    X509_free(ca_cert);
    EVP_PKEY_free(ca_pkey);
    creme_abort("x509-sign-csr: X509_REQ_get_pubkey failed");
  }
  if (X509_REQ_verify(req, req_pubkey) != 1) {
    X509_REQ_free(req);
    X509_free(ca_cert);
    EVP_PKEY_free(ca_pkey);
    EVP_PKEY_free(req_pubkey);
    creme_abort("x509-sign-csr: CSR self-signature does not verify");
  }

  X509 *cert = X509_new();
  X509_set_version(cert, 2);
  ASN1_INTEGER_set(X509_get_serialNumber(cert), X509_CERT_SERIAL_CA_SIGNED);
  X509_gmtime_adj(X509_getm_notBefore(cert), 0);
  X509_gmtime_adj(X509_getm_notAfter(cert), days * 24 * 3600);
  X509_set_pubkey(cert, req_pubkey);
  X509_set_subject_name(cert, X509_REQ_get_subject_name(req));
  X509_set_issuer_name(cert, X509_get_subject_name(ca_cert));
  int ret = X509_sign(cert, ca_pkey, EVP_sha256());

  X509_REQ_free(req);
  X509_free(ca_cert);
  EVP_PKEY_free(ca_pkey);
  EVP_PKEY_free(req_pubkey);
  if (ret == 0) {
    X509_free(cert);
    creme_abort("x509-sign-csr: X509_sign failed");
  }
  int pem_len;
  char *pem = x509_cert_to_pem(cert, &pem_len, "x509-sign-csr");
  X509_free(cert);
  return x509_cert_box(pem, pem_len);
}

/* ---- PEM import/export ------------------------------------------------------ */

static Value bi_x509_cert_to_pem(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "x509-cert->pem");
  const char *pem = x509_cert_arg(args[0], "x509-cert->pem");
  return v_str(pem, (int)strlen(pem));
}

static Value bi_pem_to_x509_cert(VM *vm, Value *args, int nargs) {
  (void)vm;
  int len;
  const char *pem = creme_arg_bytes(args, nargs, 0, "pem->x509-cert", &len);
  X509 *cert = x509_pem_to_cert(pem, len, "pem->x509-cert");
  X509_free(cert);
  return x509_cert_box(pem, len);
}

/* ---- accessors ---------------------------------------------------------------- */

static Value bi_x509_cert_subject(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "x509-cert-subject");
  const char *pem = x509_cert_arg(args[0], "x509-cert-subject");
  X509 *cert = x509_pem_to_cert(pem, (int)strlen(pem), "x509-cert-subject");
  Value result = x509_name_alist(X509_get_subject_name(cert));
  X509_free(cert);
  return result;
}

static Value bi_x509_cert_issuer(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "x509-cert-issuer");
  const char *pem = x509_cert_arg(args[0], "x509-cert-issuer");
  X509 *cert = x509_pem_to_cert(pem, (int)strlen(pem), "x509-cert-issuer");
  Value result = x509_name_alist(X509_get_issuer_name(cert));
  X509_free(cert);
  return result;
}

static Value bi_x509_cert_public_key(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "x509-cert-public-key");
  const char *pem = x509_cert_arg(args[0], "x509-cert-public-key");
  X509 *cert = x509_pem_to_cert(pem, (int)strlen(pem), "x509-cert-public-key");
  EVP_PKEY *pkey = X509_get_pubkey(cert);
  X509_free(cert);
  if (!pkey) creme_abort("x509-cert-public-key: X509_get_pubkey failed");

  Value result;
  if (EVP_PKEY_get_id(pkey) == EVP_PKEY_RSA) {
    RSA *rsa = EVP_PKEY_get1_RSA(pkey);
    EVP_PKEY_free(pkey);
    if (!rsa) creme_abort("x509-cert-public-key: EVP_PKEY_get1_RSA failed");
    result = creme_pkey_box_public_rsa(rsa);
    RSA_free(rsa);
  } else {
    EC_KEY *ec = EVP_PKEY_get1_EC_KEY(pkey);
    EVP_PKEY_free(pkey);
    if (!ec) creme_abort("x509-cert-public-key: EVP_PKEY_get1_EC_KEY failed");
    result = creme_pkey_box_public_ec(ec);
    EC_KEY_free(ec);
  }
  return result;
}

static Value bi_x509_cert_not_before(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "x509-cert-not-before");
  const char *pem = x509_cert_arg(args[0], "x509-cert-not-before");
  X509 *cert = x509_pem_to_cert(pem, (int)strlen(pem), "x509-cert-not-before");
  long long epoch = x509_asn1_time_to_epoch(X509_getm_notBefore(cert), "x509-cert-not-before");
  X509_free(cert);
  return v_float((double)epoch);
}

static Value bi_x509_cert_not_after(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "x509-cert-not-after");
  const char *pem = x509_cert_arg(args[0], "x509-cert-not-after");
  X509 *cert = x509_pem_to_cert(pem, (int)strlen(pem), "x509-cert-not-after");
  long long epoch = x509_asn1_time_to_epoch(X509_getm_notAfter(cert), "x509-cert-not-after");
  X509_free(cert);
  return v_float((double)epoch);
}

/* ---- chain verification -------------------------------------------------------- */

static Value bi_x509_verify_chain(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "x509-verify-chain");
  const char *cert_pem = x509_cert_arg(args[0], "x509-verify-chain");
  Value ca_list = args[1];
  if (ca_list.tag != T_PAIR && ca_list.tag != T_NIL) creme_abort("x509-verify-chain: expected a list of x509 certificates");

  X509 *cert = x509_pem_to_cert(cert_pem, (int)strlen(cert_pem), "x509-verify-chain");
  X509_STORE *store = X509_STORE_new();
  if (!store) {
    X509_free(cert);
    creme_abort("x509-verify-chain: X509_STORE_new failed");
  }
  for (Value cur = ca_list; cur.tag == T_PAIR; cur = cur.as.pair->cdr) {
    const char *ca_pem = x509_cert_arg(cur.as.pair->car, "x509-verify-chain");
    X509 *ca_cert = x509_pem_to_cert(ca_pem, (int)strlen(ca_pem), "x509-verify-chain");
    X509_STORE_add_cert(store, ca_cert);
    X509_free(ca_cert); /* X509_STORE_add_cert increments its own refcount */
  }

  X509_STORE_CTX *ctx = X509_STORE_CTX_new();
  if (!ctx) {
    X509_free(cert);
    X509_STORE_free(store);
    creme_abort("x509-verify-chain: X509_STORE_CTX_new failed");
  }
  if (X509_STORE_CTX_init(ctx, store, cert, NULL) != 1) {
    X509_free(cert);
    X509_STORE_free(store);
    X509_STORE_CTX_free(ctx);
    creme_abort("x509-verify-chain: X509_STORE_CTX_init failed");
  }
  int ok = X509_verify_cert(ctx);
  Value result;
  if (ok == 1) {
    result = v_bool(1);
  } else {
    int err = X509_STORE_CTX_get_error(ctx);
    const char *reason = X509_verify_cert_error_string(err);
    X509_free(cert);
    X509_STORE_free(store);
    X509_STORE_CTX_free(ctx);
    creme_abort("x509-verify-chain: %s", reason);
  }
  X509_free(cert);
  X509_STORE_free(store);
  X509_STORE_CTX_free(ctx);
  return result;
}

void creme_register_x509_builtins(VM *vm) {
  creme_register_builtin(vm, "x509-self-signed-certificate", bi_x509_self_signed_certificate);
  creme_register_builtin(vm, "x509-create-csr", bi_x509_create_csr);
  creme_register_builtin(vm, "x509-sign-csr", bi_x509_sign_csr);
  creme_register_builtin(vm, "x509-cert->pem", bi_x509_cert_to_pem);
  creme_register_builtin(vm, "pem->x509-cert", bi_pem_to_x509_cert);
  creme_register_builtin(vm, "x509-cert-subject", bi_x509_cert_subject);
  creme_register_builtin(vm, "x509-cert-issuer", bi_x509_cert_issuer);
  creme_register_builtin(vm, "x509-cert-public-key", bi_x509_cert_public_key);
  creme_register_builtin(vm, "x509-cert-not-before", bi_x509_cert_not_before);
  creme_register_builtin(vm, "x509-cert-not-after", bi_x509_cert_not_after);
  creme_register_builtin(vm, "x509-verify-chain", bi_x509_verify_chain);
}

#endif /* CREME_WITH_X509 */
