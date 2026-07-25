/* (creme string) + (creme format), backed by facil.io's fiobj_str growable
 * buffer. See strings.c's own header comment. */
#ifndef CVM_STRINGS_H
#define CVM_STRINGS_H

#include "vm.h"

void cvm_register_string_builtins(VM *vm);

#endif
