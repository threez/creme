/* (creme mux) — mux-router/mux-get!/-head!/-post!/-put!/-delete!/-patch!/
 * mux-use!/mux-listen!/mux-address/mux-base-url/mux-close!, via a single
 * poll(2)-multiplexed I/O thread + picohttpparser (vendor/picohttpparser).
 * See mux.c's own header comment for the request/response alist contract
 * this replicates from src/creme/modules/creme/mux.cr, the deliberate
 * simplifications (single router served per process, a scoped-down
 * middleware model) this prototype makes, and the full dispatch-model
 * writeup: `mux-listen!`'s optional 3rd argument is a string-keyed
 * options alist (e.g. '(("host" . "0.0.0.0") ("pool" . 8))), matching
 * this file's own request/response alist convention rather than
 * positional args -- deliberately, so native mux.cr's own mux-listen!
 * can support "host" while simply ignoring cvm-only keys like "pool"
 * instead of choking on an unexpected extra argument. "pool" picks
 * between a fixed/auto-sized worker-VM pool (#t, the default, or an
 * integer -- real parallelism, better for CPU-heavy handlers) and no
 * pool at all (#f -- zero extra threads, better for cheap/fast
 * handlers). */
#ifndef CVM_MUX_H
#define CVM_MUX_H

#include "vm.h"

void cvm_register_mux_builtins(VM *vm);

#endif
