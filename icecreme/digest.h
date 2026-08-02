/* (creme digest) — md5/sha1/sha256 hex digests + base64 encode/decode.
 * See digest.c's own header comment. */
#ifndef CREME_DIGEST_H
#define CREME_DIGEST_H

#include "vm.h"

void creme_register_digest_builtins(VM *vm);

#endif
