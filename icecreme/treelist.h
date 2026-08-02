/* (creme treelist) — a Racket-style treelist backed by an RRB (Relaxed
 * Radix Balanced) tree, giving O(log n) ref/set/add/insert/take/drop/
 * concat instead of a plain array's O(n) — see treelist.c's own header
 * comment for a full description of the port and how closely it
 * mirrors native's own src/creme/modules/creme/treelist.cr. */
#ifndef CVM_TREELIST_H
#define CVM_TREELIST_H

#include "vm.h"

void cvm_register_treelist_builtins(VM *vm);

#endif
