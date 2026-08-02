/* (creme hash-table) — a real equal?-keyed hash table, backed by Verstable
 * (vendor/verstable/verstable.h, MIT). See hashtable.c's own header comment
 * for the key design point: the Verstable map is used purely as a Scheme
 * key -> small-integer INDEX, never to hold the actual stored value — the
 * real Values live in an ordinary GC_MALLOC'd side table (also needed to
 * reconstruct native-Crystal-matching insertion order, since Verstable
 * itself doesn't preserve one). */
#ifndef CVM_HASHTABLE_H
#define CVM_HASHTABLE_H

#include "vm.h"

void cvm_register_hashtable_builtins(VM *vm);

#endif
