/* (creme builtin term) — raw-terminal primitives for a portable,
 * syntax-highlighting Scheme REPL: enter/exit cbreak mode, read one key
 * event at a time, and do small relative cursor moves/writes on the
 * current line. Mirrors src/scheme/modules/creme/term.cr exactly (same
 * procedure names/arities/alist shapes) so the SAME portable Scheme REPL
 * loop can call these regardless of which backend (cvm or native/
 * self-hosted Crystal) it's running under. See term.c's own header
 * comment for implementation notes. */
#ifndef CVM_TERM_H
#define CVM_TERM_H

#include "vm.h"

void cvm_register_term_builtins(VM *vm);

#endif
