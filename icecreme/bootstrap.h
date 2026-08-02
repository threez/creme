/* (creme bootstrap) — the icecreme-side counterpart of
 * src/creme/modules/creme/bootstrap.cr's Crystal library. Lets a running
 * icecreme program load-and-run bytecode it (or the self-hosted compiler
 * running inside it) just computed, without a live Crystal process. See
 * bootstrap.c's own header comment. */
#ifndef CREME_BOOTSTRAP_H
#define CREME_BOOTSTRAP_H

#include "vm.h"

void creme_register_bootstrap_builtins(VM *vm);

/* Set by main.c before running the compiler driver in compiler mode --
 * see icecreme-target-path in bootstrap.c. */
void creme_set_target_path(const char *path);

#endif
