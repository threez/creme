/* (creme cipher) — aes-256-gcm-encrypt/-decrypt/-random-key/-random-nonce,
 * backed by OpenSSL's EVP AEAD API. See cipher.c's own header comment. */
#ifndef CREME_CIPHER_H
#define CREME_CIPHER_H

#include "vm.h"

void creme_register_cipher_builtins(VM *vm);

#endif
