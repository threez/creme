/* (creme pkey) — RSA/EC key generation, signing/verification, RSA-OAEP
 * encryption, PEM import/export, backed by OpenSSL's EVP_PKEY/RSA/
 * EC_KEY/PEM API. See pkey.c's own header comment. */
#ifndef CVM_PKEY_H
#define CVM_PKEY_H

#include <openssl/ec.h>
#include <openssl/rsa.h>

#include "vm.h"

#define PKEY_KIND_RSA 0
#define PKEY_KIND_EC 1

/* Exposed (not kept private to pkey.c) so (creme x509) can read a pkey
 * argument's own kind/is_private/pem fields directly (e.g.
 * x509-self-signed-certificate/x509-create-csr/x509-sign-csr all take a
 * <pkey> handle as an argument) without needing a pkey.c-exported
 * accessor function per field. */
typedef struct {
  int kind; /* PKEY_KIND_RSA or PKEY_KIND_EC */
  int is_private;
  char *pem; /* GC-owned, NUL-terminated */
  int pem_len;
} PKeyBox;

void cvm_register_pkey_builtins(VM *vm);

/* Exported for (creme x509)'s x509-cert-public-key -- see pkey.c's own
 * comment on cvm_pkey_box_public_rsa/_ec. Each takes ownership of
 * neither pointer (caller still owns/frees rsa/ec). */
Value cvm_pkey_box_public_rsa(RSA *rsa);
Value cvm_pkey_box_public_ec(EC_KEY *ec);

#endif
