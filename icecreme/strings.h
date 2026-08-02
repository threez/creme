/* (creme string) + (creme format), backed by sds's growable string buffer
 * (vendor/sds). See strings.c's own header comment. */
#ifndef CVM_STRINGS_H
#define CVM_STRINGS_H

#include "vm.h"

void cvm_register_string_builtins(VM *vm);

#endif
