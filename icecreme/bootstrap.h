/* (creme bootstrap) — the icecreme-side counterpart of
 * src/creme/modules/creme/bootstrap.cr's Crystal library. Lets a running
 * icecreme program load-and-run bytecode it (or the self-hosted compiler
 * running inside it) just computed, without a live Crystal process. See
 * bootstrap.c's own header comment. */
#ifndef CREME_BOOTSTRAP_H
#define CREME_BOOTSTRAP_H

#include "vm.h"

void creme_register_bootstrap_builtins(VM *vm);

/* Set by embed.c's creme_run_scheme_file before running the compiler driver,
 * to hand it a specific file to compile+run -- see icecreme-target-path in
 * bootstrap.c. The CLI (main.c) leaves it unset and forwards its argv to the
 * dispatcher via (command-line) instead, so icecreme-target-path returns #f
 * there. */
void creme_set_target_path(const char *path);

#endif
