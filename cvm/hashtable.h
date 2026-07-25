/* (creme hash-table) — a real equal?-keyed hash table, backed by facil.io's
 * fiobj_hash (lib/facil/fiobj/fiobj_hash.h). See hashtable.c's own header
 * comment for the key design point: FIOBJ is used purely as a structural-
 * equality/hash INDEX (Scheme key -> a small integer), never to hold the
 * actual stored value — the real Values live in an ordinary GC_MALLOC'd
 * side table, so Boehm GC can see them regardless of what facil.io's own
 * (non-GC, refcounted) allocator does with the FIOBJ objects themselves. */
#ifndef CVM_HASHTABLE_H
#define CVM_HASHTABLE_H

#include "vm.h"

void cvm_register_hashtable_builtins(VM *vm);

#endif
