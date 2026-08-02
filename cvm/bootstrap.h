/* (creme bootstrap) — the cvm-side counterpart of
 * src/creme/modules/creme/bootstrap.cr's Crystal library. Lets a running
 * cvm program load-and-run bytecode it (or the self-hosted compiler
 * running inside it) just computed, without a live Crystal process. See
 * bootstrap.c's own header comment. */
#ifndef CVM_BOOTSTRAP_H
#define CVM_BOOTSTRAP_H

#include "vm.h"

void cvm_register_bootstrap_builtins(VM *vm);

/* Set by main.c before running the compiler driver in compiler mode --
 * see cvm-target-path in bootstrap.c. */
void cvm_set_target_path(const char *path);

#endif
