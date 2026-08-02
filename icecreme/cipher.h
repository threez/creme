/* (creme cipher) — aes-256-gcm-encrypt/-decrypt/-random-key/-random-nonce,
 * backed by OpenSSL's EVP AEAD API. See cipher.c's own header comment. */
#ifndef CVM_CIPHER_H
#define CVM_CIPHER_H

#include "vm.h"

void cvm_register_cipher_builtins(VM *vm);

#endif
