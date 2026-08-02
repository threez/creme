/* (creme secure-random) — secure-random-bytes/-hex/-base64, backed by
 * OpenSSL's RAND_bytes. See secure_random.c's own header comment. */
#ifndef CREME_SECURE_RANDOM_H
#define CREME_SECURE_RANDOM_H

#include "vm.h"

void creme_register_secure_random_builtins(VM *vm);

#endif
