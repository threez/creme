/* (creme secure-random) — secure-random-bytes/-hex/-base64, backed by
 * OpenSSL's RAND_bytes. See secure_random.c's own header comment. */
#ifndef CVM_SECURE_RANDOM_H
#define CVM_SECURE_RANDOM_H

#include "vm.h"

void cvm_register_secure_random_builtins(VM *vm);

#endif
