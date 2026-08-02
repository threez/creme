/* (creme digest) — md5/sha1/sha256 hex digests + base64 encode/decode.
 * See digest.c's own header comment. */
#ifndef CVM_DIGEST_H
#define CVM_DIGEST_H

#include "vm.h"

void cvm_register_digest_builtins(VM *vm);

#endif
