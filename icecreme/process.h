/* (creme process) -- a narrow slice (just `process-run`) of the real
 * Crystal-side (creme process) library, backed by POSIX fork/exec. See
 * process.c's own header comment. */
#ifndef CVM_PROCESS_H
#define CVM_PROCESS_H

#include "vm.h"

void cvm_register_process_builtins(VM *vm);

#endif
