/* (creme mux) — mux-router/mux-get!/-head!/-post!/-put!/-delete!/-patch!/
 * mux-use!/mux-listen!/mux-address/mux-base-url/mux-close!, via facil.io's
 * http.h. See mux.c's own header comment for the request/response alist
 * contract this replicates from src/scheme/modules/creme/mux.cr, and for
 * the deliberate simplifications (single router served per process, a
 * scoped-down middleware model) this prototype makes. */
#ifndef CVM_MUX_H
#define CVM_MUX_H

#include "vm.h"

void cvm_register_mux_builtins(VM *vm);

#endif
