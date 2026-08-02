/* (creme string) + (creme format), backed by sds's growable string buffer
 * (vendor/sds). See strings.c's own header comment. */
#ifndef CREME_STRINGS_H
#define CREME_STRINGS_H

#include "vm.h"

void creme_register_string_builtins(VM *vm);

#endif
